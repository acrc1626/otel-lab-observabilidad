# Fase 2 — OTel Collector (Luis)

## Qué incluye este paquete
- `otel-collector-config-aws.yaml` / `otel-collector-config-gcp.yaml`: mismo pipeline base, pero difieren en el destino de trazas y logs (AWS: X-Ray + CloudWatch; GCP: Jaeger + Cloud Logging). Métricas van a Prometheus en ambas — es el único backend centralizado y compartido. Cada archivo solo declara los exporters que esa nube realmente usa (el Collector valida hasta los que no usa, ver apéndice). Las dos configs quedan horneadas en la **misma imagen** — Terraform le dice a cada despliegue cuál cargar (vía `command`/`args`), no una variable de entorno dentro del YAML (eso causó un crash real, ver el apéndice).
- `Dockerfile`: imagen basada en `otel-collector-contrib`, con las dos configs incluidas.
- `terraform/aws/`: ECR (referenciado, se crea a mano), log groups, IAM (incluye permisos de X-Ray), cluster ECS, security group compartido, y **3 servicios independientes** — Collector, Jaeger y Prometheus, cada uno en su propia tarea/ENI (no comparten red entre sí).
- `terraform/gcp/`: Artifact Registry (referenciado) y un servicio de Cloud Run para el Collector — le exporta trazas directo a Jaeger y métricas directo a Prometheus, ambos en AWS, sin pasar por el Collector de AWS.

Todo el despliegue de infraestructura es por Terraform. Lo único manual, en ambas nubes, es construir y subir la imagen Docker — Terraform no compila imágenes.

---

## Paso 0 — Construir la imagen (una sola vez, sirve para las dos nubes)
```bash
cd otel-collector
docker build -t otel-collector:latest .
```

---

## AWS

**1. Crear el repositorio en ECR** (una vez, si no existe — se maneja fuera de Terraform a propósito, ver apéndice)
```bash
aws ecr create-repository --repository-name otel-collector --region us-east-1
```

**2. Login, tag y push**
```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com

docker tag otel-collector:latest <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/otel-collector:latest
docker push <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/otel-collector:latest
```
`<ACCOUNT_ID>` es el número de cuenta de AWS (12 dígitos). Para obtenerlo directo, sin tener que copiarlo a mano del JSON completo:
```bash
aws sts get-caller-identity --query Account --output text
```

**3. Desplegar — en dos pasos**

Ahora son **3 servicios independientes** (Collector, Jaeger, Prometheus — ya no comparten tarea), cada uno con su propio ENI/IP pública. Esto crea una dependencia circular chiquita: el Collector necesita saber la IP de Prometheus para exportarle métricas, pero esa IP no existe hasta que Prometheus ya esté desplegado. Por eso el primer `apply` usa una IP de relleno, y el segundo ya usa la real:

```bash
cd terraform/aws
terraform init

# Paso 3a: primer apply, sin la IP real de Prometheus todavía (usa el default "0.0.0.0")
terraform apply -var="collector_image=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/otel-collector:latest"
```
Esto crea: log groups, roles IAM (incluyendo permisos de X-Ray para el Collector), cluster ECS, security group compartido, y las 3 tareas.

```bash
# Paso 3b: obtener la IP real de Prometheus
terraform output get_prometheus_public_ip_command
# corre el comando que te imprime, o repite el patrón manual con aws ecs describe-tasks / aws ec2 describe-network-interfaces
```

```bash
# Paso 3c: segundo apply, ahora sí con la IP real — esto redespliega SOLO el Collector
# (Jaeger y Prometheus no cambian, ya están corriendo bien desde el paso 3a)
terraform apply \
  -var="collector_image=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/otel-collector:latest" \
  -var="prometheus_public_ip=<IP_DE_PROMETHEUS>"
```

**4. Obtener las otras dos IPs públicas** (Collector y Jaeger — las vas a necesitar para GCP y para validar)
```bash
terraform output get_collector_public_ip_command
terraform output get_jaeger_public_ip_command
```
Con las IPs: Jaeger UI en `http://<IP_JAEGER>:16686`, Prometheus en `http://<IP_PROMETHEUS>:9090`, healthcheck del Collector en `http://<IP_COLLECTOR>:13133/`. Las trazas de AWS ya no pasan por Jaeger — van a **AWS X-Ray**, revisa la consola de X-Ray en vez de Jaeger UI para esas.

**5. Probar manualmente con `curl`** (sin esperar a los microservicios de Astrid)

Todo se manda al **Collector** (nunca directo a Jaeger/Prometheus/X-Ray) — el Collector es quien decide a dónde reenviar.

Trazas (puerto 4318 = OTLP HTTP):
```bash
EPOCH_HEX=$(printf '%08x' $(date +%s))
TRACE_ID="${EPOCH_HEX}$(openssl rand -hex 12)"
SPAN_ID=$(openssl rand -hex 8)
NOW=$(date +%s%N)
END=$((NOW + 1000000000))

curl -X POST http://<IP_COLLECTOR>:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"prueba-manual-aws\"}}]},\"scopeSpans\":[{\"spans\":[{\"traceId\":\"$TRACE_ID\",\"spanId\":\"$SPAN_ID\",\"name\":\"span-de-prueba-xray\",\"kind\":1,\"startTimeUnixNano\":\"$NOW\",\"endTimeUnixNano\":\"$END\"}]}]}]}"
```
Respuesta esperada: `{"partialSuccess":{}}` (vacío = éxito). Revisa en la consola de **X-Ray** (`us-east-1`, filtro de tiempo "Last 5 minutes").

> El `TRACE_ID` no puede ser cualquier string aleatorio: X-Ray exige que los primeros 8 caracteres hex representen la fecha/hora Unix actual. Si usas un ID con una fecha vieja incrustada, X-Ray descarta el segmento en silencio, sin ningún error visible — el comando de arriba ya genera el ID con el formato correcto.

Métricas (mismo Collector, misma IP, ruta `/v1/metrics`):
```bash
NOW=$(date +%s%N)
curl -X POST http://<IP_COLLECTOR>:4318/v1/metrics \
  -H "Content-Type: application/json" \
  -d "{\"resourceMetrics\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"prueba-manual-aws\"}}]},\"scopeMetrics\":[{\"metrics\":[{\"name\":\"prueba_metrica_aws\",\"gauge\":{\"dataPoints\":[{\"asDouble\":42,\"timeUnixNano\":\"$NOW\"}]}}]}]}]}"
```
Revisa en **Prometheus** (`http://<IP_PROMETHEUS>:9090`, no la IP del Collector) — en el cuadro de búsqueda escribe solo el nombre de la métrica: `prueba_metrica_aws`. Un solo `curl` te da una línea recta (un único punto) — para una gráfica con variación real:
```bash
for i in $(seq 1 20); do
  VALUE=$((RANDOM % 100))
  NOW=$(date +%s%N)
  curl -s -X POST http://<IP_COLLECTOR>:4318/v1/metrics \
    -H "Content-Type: application/json" \
    -d "{\"resourceMetrics\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"prueba-manual-aws\"}}]},\"scopeMetrics\":[{\"metrics\":[{\"name\":\"prueba_metrica_aws\",\"gauge\":{\"dataPoints\":[{\"asDouble\":$VALUE,\"timeUnixNano\":\"$NOW\"}]}}]}]}]}" > /dev/null
  sleep 5
done
```

> Trazas y métricas son dos rutas OTLP distintas (`/v1/traces` vs `/v1/metrics`), por eso hacen falta dos peticiones separadas al probar a mano con `curl`. En una app real instrumentada con el SDK de OTel esto no lo notas — el SDK genera y despacha ambas señales automáticamente a partir del mismo código.

**6. Si haces cambios y vuelves a subir la imagen al mismo tag `latest`**
El tag mutable no siempre dispara un redeploy automático en Terraform. Fuerza uno (ajusta `--service` al que corresponda: `otel-collector`, `jaeger` o `prometheus`):
```bash
aws ecs update-service --cluster otel-lab-cluster --service otel-collector --force-new-deployment
```

**7. Pausar sin destruir infraestructura** (mientras depuras algo, para no seguir pagando)
```bash
aws ecs update-service --cluster otel-lab-cluster --service otel-collector --desired-count 0
aws ecs update-service --cluster otel-lab-cluster --service jaeger --desired-count 0
aws ecs update-service --cluster otel-lab-cluster --service prometheus --desired-count 0
# para reanudar cualquiera: --desired-count 1
```

---

## GCP

**1. Login y elegir el proyecto**
```bash
gcloud auth login
```
*(si `gcloud` no está instalado, o si cualquier comando de `gcloud` falla con `certificate verify failed`, ve al apéndice — proxy corporativo, mismo problema que con `aws-cli`)*

Intenta crear un proyecto dedicado para el lab:
```bash
gcloud projects create otel-lab-observabilidad --name="OTel Lab Observabilidad"
gcloud config set project otel-lab-observabilidad   # si el create funcionó
```
Si falla con `exceeded your allotted project quota` *(común si ya tenías otros proyectos, incluso "borrados" — quedan contando ~30 días de gracia)*, usa el proyecto que Google ya te creó automáticamente al registrarte:
```bash
gcloud projects list
# busca el de nombre genérico tipo "Default Gemini Project" (gen-lang-client-...)
gcloud config set project <TU_PROJECT_ID>
```

Confirma que la facturación esté vinculada:
```bash
gcloud billing projects describe <TU_PROJECT_ID>
```
Busca `billingEnabled: true`. Si dice `false`: `https://console.cloud.google.com/billing/linkedaccount?project=<TU_PROJECT_ID>`
*(si venías de un Free Trial y ya se convirtió a cuenta de pago, es normal e irreversible — el crédito no usado se sigue consumiendo primero de todas formas)*

**2. Habilitar las APIs necesarias**

Un proyecto nuevo (o poco usado, como el "Default Gemini Project") trae casi todas las APIs desactivadas — no solo las obvias (Artifact Registry, Cloud Run), también dos que Terraform necesita internamente para funcionar y que no son evidentes hasta que fallan a mitad de un `apply`:
```bash
gcloud services enable \
  artifactregistry.googleapis.com \
  run.googleapis.com \
  serviceusage.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project=<TU_PROJECT_ID>
```
Espera 30-60 segundos después de correr esto — la activación tarda en propagarse antes de que otros comandos la reconozcan.

**3. Crear el repositorio en Artifact Registry y subir la imagen**
```bash
gcloud artifacts repositories create observability \
  --repository-format=docker --location=us-central1 \
  --description="Imagenes del lab de observabilidad" \
  --project=<TU_PROJECT_ID>

gcloud auth configure-docker us-central1-docker.pkg.dev

docker tag otel-collector:latest us-central1-docker.pkg.dev/<TU_PROJECT_ID>/observability/otel-collector:latest
docker push us-central1-docker.pkg.dev/<TU_PROJECT_ID>/observability/otel-collector:latest
```
*(si Docker Desktop no está corriendo, `docker tag` falla con un error de "pipe"/conexión — ábrelo y reintenta. Para ver el repo en la consola: busca "Artifact Registry" en el buscador de arriba, no siempre aparece en el menú lateral ☰)*

**4. Autenticar Terraform (cuenta de servicio)**

`gcloud auth login` autentica el CLI, pero **Terraform necesita sus propias credenciales** (Application Default Credentials) — son dos mecanismos separados. El camino obvio, `gcloud auth application-default login`, suele fallar en redes corporativas porque depende de un redirect a `localhost` que el proxy bloquea (y su alternativa `--no-browser`/`--remote-bootstrap` está pensada para correrse en una segunda máquina, no en la misma). El camino confiable es darle a Terraform una cuenta de servicio propia, autenticada con tu sesión normal de `gcloud auth login` (que sí funciona bien):
```bash
gcloud iam service-accounts create terraform-otel-lab --display-name="Terraform OTel Lab" --project=<TU_PROJECT_ID>

gcloud projects add-iam-policy-binding <TU_PROJECT_ID> --member="serviceAccount:terraform-otel-lab@<TU_PROJECT_ID>.iam.gserviceaccount.com" --role="roles/run.admin"
gcloud projects add-iam-policy-binding <TU_PROJECT_ID> --member="serviceAccount:terraform-otel-lab@<TU_PROJECT_ID>.iam.gserviceaccount.com" --role="roles/iam.serviceAccountUser"
gcloud projects add-iam-policy-binding <TU_PROJECT_ID> --member="serviceAccount:terraform-otel-lab@<TU_PROJECT_ID>.iam.gserviceaccount.com" --role="roles/artifactregistry.reader"
gcloud projects add-iam-policy-binding <TU_PROJECT_ID> --member="serviceAccount:terraform-otel-lab@<TU_PROJECT_ID>.iam.gserviceaccount.com" --role="roles/serviceusage.serviceUsageAdmin"

gcloud iam service-accounts keys create ~/terraform-otel-lab-key.json --iam-account=terraform-otel-lab@<TU_PROJECT_ID>.iam.gserviceaccount.com

export GOOGLE_APPLICATION_CREDENTIALS="/c/Users/<tu_usuario>/terraform-otel-lab-key.json"
```
Terraform detecta esa variable de entorno automáticamente. La clave `.json` es sensible — ya está en `.gitignore`, nunca la subas al repo.

**5. Desplegar en Cloud Run**

Jaeger y Prometheus ya están corriendo en AWS (cada uno en su propia tarea, con su propia IP pública) — el Collector de GCP le exporta a cada uno directamente, sin pasar por el Collector de AWS. A diferencia de GKE, aquí no hay clúster, VPC ni subnets que crear.
```bash
cd terraform/gcp
terraform init
terraform apply \
  -var="project_id=<TU_PROJECT_ID>" \
  -var="collector_image=us-central1-docker.pkg.dev/<TU_PROJECT_ID>/observability/otel-collector:latest" \
  -var="aws_jaeger_public_ip=<IP_DE_JAEGER>" \
  -var="aws_prometheus_public_ip=<IP_DE_PROMETHEUS>"
```
Ambas IPs salen de la sección de AWS (`terraform output get_jaeger_public_ip_command` y `get_prometheus_public_ip_command`).

*(si el `apply` falla con algo como "repository not found", el repo del paso 3 no quedó creado en el mismo proyecto que le estás pasando en `project_id`. Si falla el recurso `google_cloud_run_v2_service_iam_member` de acceso público, puede ser una política organizacional que restrinja compartir con `allUsers` — poco probable en cuenta personal)*

**6. Obtener la URL pública del Collector**
```bash
terraform output collector_url
```
A diferencia de AWS (una IP + puerto plano), Cloud Run te da una URL HTTPS (`https://otel-collector-xxxxx-uc.a.run.app`), sin puerto explícito. Esa URL enruta al receiver **HTTP** de OTLP (equivalente al `:4318` de AWS) — usa las rutas `/v1/traces`, `/v1/metrics` con `Content-Type: application/json`. Los microservicios de GCP deben mandar su OTLP ahí **con TLS habilitado** (no `insecure=true` como en AWS, porque Cloud Run exige HTTPS de cara al público). Si tu SDK está configurado para gRPC en vez de HTTP, no va a funcionar contra esta URL — ver la nota en `terraform/gcp/main.tf` sobre cómo cambiar el puerto expuesto a 4317 si lo necesitas.

**7. Probar manualmente con `curl`**

Mismo patrón que en AWS, pero contra la URL de Cloud Run — sin puerto en la URL, con `--cacert` si tu red tiene inspección SSL corporativa (ver apéndice):
```bash
EPOCH_HEX=$(printf '%08x' $(date +%s))
TRACE_ID="${EPOCH_HEX}$(openssl rand -hex 12)"
SPAN_ID=$(openssl rand -hex 8)
NOW=$(date +%s%N)
END=$((NOW + 1000000000))

curl -i --cacert "/c/Users/<tu_usuario>/aws-ca-bundle.pem" -X POST <TU_COLLECTOR_URL>/v1/traces \
  -H "Content-Type: application/json" \
  -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"prueba-manual-gcp\"}}]},\"scopeSpans\":[{\"spans\":[{\"traceId\":\"$TRACE_ID\",\"spanId\":\"$SPAN_ID\",\"name\":\"span-de-prueba-gcp\",\"kind\":1,\"startTimeUnixNano\":\"$NOW\",\"endTimeUnixNano\":\"$END\"}]}]}]}"
```
Revisa en **Jaeger UI** (`http://<IP_JAEGER>:16686`, la IP de AWS) — cambia el desplegable "Service" de `jaeger-all-in-one` (que es Jaeger monitoreándose a sí mismo) a `prueba-manual-gcp`.

```bash
NOW=$(date +%s%N)
curl -i --cacert "/c/Users/<tu_usuario>/aws-ca-bundle.pem" -X POST <TU_COLLECTOR_URL>/v1/metrics \
  -H "Content-Type: application/json" \
  -d "{\"resourceMetrics\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"prueba-manual-gcp\"}}]},\"scopeMetrics\":[{\"metrics\":[{\"name\":\"prueba_metrica_gcp\",\"gauge\":{\"dataPoints\":[{\"asDouble\":77,\"timeUnixNano\":\"$NOW\"}]}}]}]}]}"
```
Revisa en **Prometheus** (`http://<IP_PROMETHEUS>:9090`, la misma IP compartida de siempre) — busca `prueba_metrica_gcp`, o para ver ambas nubes juntas en una sola consulta: `up{cloud_provider="gcp"}` y `up{cloud_provider="aws"}`.

---

## Validar el pipeline completo (resumen)
- Trazas de AWS → consola de **X-Ray** (`us-east-1`).
- Trazas de GCP → **Jaeger UI** (`http://<IP_JAEGER>:16686`), filtrando por servicio.
- Métricas de ambas nubes → **Prometheus** (`http://<IP_PROMETHEUS>:9090`), un solo backend compartido.
- Logs de AWS → **CloudWatch**. Logs de GCP → **Cloud Logging**.
- Healthcheck del Collector de AWS: `GET http://<IP_COLLECTOR>:13133/`. El de GCP no es accesible públicamente (Cloud Run solo enruta al puerto principal) — revisa el estado del servicio en la consola de Cloud Run en su lugar.

## Pendiente para el reporte técnico
- [ ] Capturas del healthcheck del Collector de AWS.
- [ ] Captura de la consola de AWS X-Ray con trazas de los microservicios de AWS.
- [ ] Captura de Jaeger UI con trazas de los microservicios de GCP.
- [ ] Captura de Prometheus mostrando métricas etiquetadas `cloud.provider=aws` y `cloud.provider=gcp` — evidencia de correlación cross-cloud en el backend de métricas.
- [ ] Explicación breve en el reporte de por qué las trazas se dividen así (siguiendo el enunciado de la actividad: Jaeger para GCP, X-Ray para AWS) mientras que las métricas sí quedan centralizadas en un solo Prometheus.
- [ ] Diagrama actualizado del pipeline (los 3 servicios separados en AWS + Cloud Run en GCP).
- [ ] Captura del `terraform apply` exitoso en ambas nubes.

## Limpieza (evitar gastar créditos de más)
```bash
cd terraform/aws && terraform destroy
cd ../gcp && terraform destroy
```

---

## Apéndice — Problemas ya resueltos (para no repetir la investigación)

### Error SSL: `certificate verify failed: unable to get local issuer certificate` (aws-cli)
Proxy corporativo con inspección SSL (Zscaler, Netskope, etc.). `aws-cli` no confía en su certificado por defecto.
1. Exporta el certificado raíz del proxy desde el navegador (candado → ver certificado → Exportar → Base-64 X.509).
2. Descarga https://curl.se/ca/cacert.pem, pega el certificado del proxy al final, guarda como `aws-ca-bundle.pem`.
3. `export AWS_CA_BUNDLE="/c/Users/<tu_usuario>/aws-ca-bundle.pem"` (agrégalo a `~/.bashrc`).

### `gcloud` + certificado corporativo: `certificate verify failed`
Mismo proxy, `gcloud` no usa `AWS_CA_BUNDLE` — usa su propia config, pero reutiliza el mismo archivo:
```bash
gcloud config set core/custom_ca_certs_file "/c/Users/<tu_usuario>/aws-ca-bundle.pem"
```
Config persistente (no una variable de sesión), no hay que repetirla en cada terminal.

### `curl` directo a HTTPS también falla con el mismo error SSL
Tercera herramienta, mismo proxy. Solo pasa contra HTTPS (por eso no lo viste probando contra AWS, que expone HTTP plano) — sí te pasa contra Cloud Run.
```bash
export CURL_CA_BUNDLE="/c/Users/<tu_usuario>/aws-ca-bundle.pem"
echo 'export CURL_CA_BUNDLE="/c/Users/<tu_usuario>/aws-ca-bundle.pem"' >> ~/.bashrc
```
O puntual, sin dejarlo persistente: `curl --cacert "/c/Users/<tu_usuario>/aws-ca-bundle.pem" ...`

### Error `InvalidClientTokenId`
El perfil `default` de AWS CLI tiene una Access Key inválida. Si VS Code muestra "Connected" con un perfil con nombre, usa ese:
```bash
export AWS_PROFILE=<tu-perfil-bueno>
```

### El repositorio de ECR/Artifact Registry se crea fuera de Terraform, a propósito
Evita el problema de "quién lo crea primero" (necesitas el repo para el `docker push`, pero antes de tener nada que desplegar). Terraform solo lo referencia como recurso existente (`data` source), nunca lo crea ni lo destruye.

### El Collector crashea con `cannot resolve the configuration: retrieved value (type=string) cannot be used as a Conf`
Causa: una variable `${env:VAR}` usada como elemento suelto dentro de una lista YAML (ej. `exporters: [${env:LOG_EXPORTER}, debug]`) en vez de como valor completo de un campo. Solución adoptada en este repo: dos archivos de config completos (uno por nube) horneados en la misma imagen, seleccionados por `command`/`args` desde Terraform.

Para diagnosticar sin gastar en ciclos de despliegue: reprodúcelo en local con `docker run`. Si el log sale cortado, usa `docker run -d --name debug ... && docker logs debug` en vez de `--rm` en primer plano.

### El Collector no arranca con `invalid configuration: exporters::<algo>: '<campo>' must be set`
Causa: **el Collector valida TODOS los exporters declarados en el YAML, incluso los que no están referenciados en ningún pipeline activo**. Si declaras un exporter (ej. `awscloudwatchlogs` en la config de GCP) con un campo obligatorio que depende de una variable nunca seteada en esa nube, el Collector no arranca — ni abre el puerto OTLP. En Cloud Run esto se ve como "el contenedor no escuchó a tiempo" (mensaje engañoso).

Solución: cada archivo de config solo debe declarar los exporters que esa nube realmente usa — quita el bloque que no corresponde, no lo dejes "por si acaso".

### Las peticiones a Cloud Run responden con HTTP 415 (Unsupported Media Type)
Causa: Cloud Run solo expone UN puerto por servicio. Si ese puerto es `4317`/`h2c` (gRPC) pero mandas JSON por HTTP/1.1 (como los `curl` de este README), el receiver equivocado recibe la petición y la rechaza. Solución adoptada: exponer `4318` (HTTP) en vez de `4317` en `terraform/gcp/main.tf`.

### `gcloud projects create` falla con "exceeded your allotted project quota"
Ya cubierto en el Paso 1 de la sección GCP — usa el proyecto por defecto en vez de pelear con la cuota.

### `terraform apply` en GCP falla con "could not find default credentials"
Ya cubierto en el Paso 4 de la sección GCP — usa una cuenta de servicio en vez de `gcloud auth application-default login`.

### Una traza de prueba llega al Collector (`partialSuccess`) pero no aparece en X-Ray
Ver el Paso 5 de AWS — es el formato del `traceId`, X-Ray exige que los primeros 8 caracteres hex sean la fecha/hora Unix actual, y descarta en silencio cualquier traza que no cumpla eso.

### El tag `latest` no dispara redeploy automático en ECS
Terraform compara el texto de la variable `collector_image`, no el contenido real de la imagen. Fuerza el redeploy manualmente (ver sección AWS, paso 6).

### El Collector crashea con `listen tcp 0.0.0.0:4317: bind: address already in use`
Causa: Jaeger, con `COLLECTOR_OTLP_ENABLED=true`, levanta su propio receptor OTLP en los mismos puertos que el Collector (4317/4318) — si comparten red (misma ECS Task), chocan. **Ya no aplica** en este repo (Jaeger y Prometheus corren en sus propias tareas, cada una con su propio ENI, sin conflicto de puertos) — se deja documentado por si alguna vez vuelves a compartir tareas por razones de costo.
