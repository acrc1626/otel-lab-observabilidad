# Fase 2 — OTel Collector (Luis)

## Qué incluye este paquete
- `otel-collector-config-aws.yaml` / `otel-collector-config-gcp.yaml`: mismo pipeline base, pero difieren en el destino de trazas y logs (AWS: X-Ray + CloudWatch; GCP: Jaeger + Cloud Logging). Métricas van a Prometheus en ambas — es el único backend centralizado y compartido. Cada archivo solo declara los exporters que esa nube realmente usa (el Collector valida hasta los que no usa, ver apéndice). Las dos configs quedan horneadas en la **misma imagen** — Terraform le dice a cada despliegue cuál cargar (vía `command`/`args`), no una variable de entorno dentro del YAML (eso causó un crash real, ver el apéndice).
- `Dockerfile`: imagen basada en `otel-collector-contrib`, con las dos configs incluidas.
- `service-a/`: el microservicio real de Astrid (FastAPI + OTel SDK) — ya lee `OTEL_EXPORTER_OTLP_ENDPOINT` del entorno, no necesita cambios de código.
- `terraform/aws/`: ECR (referenciado, se crea a mano), log groups, IAM (incluye permisos de X-Ray), cluster ECS, security group compartido, y **4 servicios independientes** — Collector, Jaeger, Prometheus y service-a, cada uno en su propia tarea/ENI (no comparten red entre sí).
- `terraform/gcp/`: Artifact Registry (referenciado) y un servicio de Cloud Run para el Collector — le exporta trazas directo a Jaeger y métricas directo a Prometheus, ambos en AWS, sin pasar por el Collector de AWS.

---

## Paso 0 — Construir la imagen de `otel-collector` (una sola vez, sirve para las dos nubes)
```bash
cd otel-collector
docker build -t otel-collector:latest .
```
Esta misma imagen se publica en dos registries distintos más abajo (ECR y Artifact Registry) — no hay que reconstruirla por nube.

---

## AWS

### 0. Confirmar (o cambiar) la cuenta activa

Antes de crear nada, confirma con cuál cuenta/perfil vas a trabajar — tienes varios perfiles guardados y es fácil terminar en el equivocado:
```bash
aws sts get-caller-identity
```
Te muestra el `Account` activo. Si no es el que quieres:
```bash
aws configure list-profiles          # ver qué perfiles tienes disponibles
export AWS_PROFILE=<nombre-del-perfil>
aws sts get-caller-identity          # confirma que ya cambió
```
*(si te da error de credenciales o SSL, ver apéndice)*

### 1. Imágenes (repos + build + tag + push)

**otel-collector** (ya construida en el Paso 0 — aquí solo se crea el repo y se sube):
```bash
aws ecr create-repository --repository-name otel-collector --region us-east-1

aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com

docker tag otel-collector:latest <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/otel-collector:latest
docker push <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/otel-collector:latest
```
`<ACCOUNT_ID>` (12 dígitos): `aws sts get-caller-identity --query Account --output text`

**service-a** (repo, build y push completos — esta imagen es nueva, no se construyó en el Paso 0):

> El login de Docker a ECR (paso anterior) expira cada ~12h. Si pasó tiempo desde que lo hiciste y el `push` falla con `denied: Your authorization token has expired`, repite el `aws ecr get-login-password | docker login ...` de arriba antes de seguir.
```bash
aws ecr create-repository --repository-name service-a --region us-east-1

cd service-a
docker build -t service-a:latest .
docker tag service-a:latest <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/service-a:latest
docker push <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/service-a:latest
cd ..
```

Al terminar esta sección: dos imágenes en ECR (`otel-collector` y `service-a`), nada desplegado todavía.

### 2. Desplegar con Terraform

Son **4 servicios independientes** (Collector, Jaeger, Prometheus, service-a — ninguno comparte tarea), cada uno con su propio ENI/IP pública. Como ya construiste las dos imágenes en el paso anterior, el primer `apply` ya puede crear los 4 servicios de una vez — lo único que falta son las **IPs**, que no existen hasta que algo ya está corriendo (por eso arrancan con un valor de relleno y se corrigen en un segundo `apply`):

```bash
cd terraform/aws
terraform init

# Primer apply: las dos imágenes YA las tienes, así que van desde ahora.
# prometheus_public_ip y collector_public_ip usan su default "0.0.0.0" —
# el Collector y service-a arrancan "a ciegas" por un momento, se corrige abajo.
terraform apply \
  -var="collector_image=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/otel-collector:latest" \
  -var="service_a_image=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/service-a:latest"
```
Esto crea: log groups, roles IAM (incluyendo permisos de X-Ray), cluster ECS, security group compartido, y las 4 tareas.

```bash
# Obtener las IPs reales de Prometheus y del Collector
terraform output get_prometheus_public_ip_command
terraform output get_collector_public_ip_command

# Segundo apply: mismas dos imágenes + las dos IPs reales — redespliega
# SOLO el Collector y service-a (Jaeger y Prometheus no cambian)
terraform apply \
  -var="collector_image=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/otel-collector:latest" \
  -var="service_a_image=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/service-a:latest" \
  -var="prometheus_public_ip=<IP_DE_PROMETHEUS>" \
  -var="collector_public_ip=<IP_DEL_COLLECTOR>"
```

**Obtener el resto de las IPs** (Jaeger y service-a):
```bash
terraform output get_jaeger_public_ip_command
terraform output get_service_a_public_ip_command
```
Jaeger UI: `http://<IP_JAEGER>:16686` · Prometheus: `http://<IP_PROMETHEUS>:9090` · healthcheck del Collector: `http://<IP_COLLECTOR>:13133/`. Las trazas de AWS van a **X-Ray**, no a Jaeger.

*(si haces cambios y vuelves a subir una imagen al mismo tag `latest`, Terraform no siempre detecta el cambio — fuerza el redeploy: `aws ecs update-service --cluster otel-lab-cluster --service <nombre-del-servicio> --force-new-deployment`)*

> **Importante**: de aquí en adelante, **todo `terraform apply` en esta carpeta necesita las 4 variables** (`collector_image`, `service_a_image`, `prometheus_public_ip`, `collector_public_ip`) — como los 4 servicios ya existen en el estado de Terraform, un `apply` que omita alguna te la va a preguntar de forma interactiva, y si la dejas vacía por error (como pasó con `service_a_image` antes de este ajuste), el despliegue de ese servicio falla. Guarda el comando completo del segundo `apply` de arriba en algún lado para reusarlo tal cual.

### 3. Probar manualmente con `curl`

Todo se manda al **Collector** (nunca directo a Jaeger/Prometheus/X-Ray) — el Collector decide a dónde reenviar. Trazas y métricas son dos rutas OTLP distintas (`/v1/traces` vs `/v1/metrics`) — en una app real el SDK las despacha solo, aquí las simulamos a mano.

**Trazas** (puerto 4318 = OTLP HTTP):
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
Respuesta esperada: `{"partialSuccess":{}}`. Revisa en **X-Ray** (`us-east-1`, "Last 5 minutes").
> El `TRACE_ID` no es cualquier string: X-Ray exige que los primeros 8 caracteres hex sean la fecha/hora Unix actual — el comando de arriba ya lo genera bien.

**Métricas**:
```bash
NOW=$(date +%s%N)
curl -X POST http://<IP_COLLECTOR>:4318/v1/metrics \
  -H "Content-Type: application/json" \
  -d "{\"resourceMetrics\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"prueba-manual-aws\"}}]},\"scopeMetrics\":[{\"metrics\":[{\"name\":\"prueba_metrica_aws\",\"gauge\":{\"dataPoints\":[{\"asDouble\":42,\"timeUnixNano\":\"$NOW\"}]}}]}]}]}"
```
Revisa en **Prometheus** (`http://<IP_PROMETHEUS>:9090`) — busca `prueba_metrica_aws`. Un solo `curl` da una línea recta; para una gráfica con variación real:
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

**service-a (el microservicio real)**:
```bash
curl http://<IP_SERVICE_A>:8000/health
curl -X POST http://<IP_SERVICE_A>:8000/order -H "Content-Type: application/json" -d '{"item":"prueba-real"}'
```
El segundo `curl` va a fallar con `502` (porque `service-b` todavía no existe) — **eso está bien por ahora**, lo importante es revisar **X-Ray**: debería aparecer una traza real generada por FastAPI, con el span automático de la petición HTTP y tu span custom `validate_order` anidado.

**Pausar sin destruir infraestructura** (mientras depuras algo, para no seguir pagando):
```bash
aws ecs update-service --cluster otel-lab-cluster --service otel-collector --desired-count 0
aws ecs update-service --cluster otel-lab-cluster --service jaeger --desired-count 0
aws ecs update-service --cluster otel-lab-cluster --service prometheus --desired-count 0
aws ecs update-service --cluster otel-lab-cluster --service service-a --desired-count 0
# para reanudar cualquiera: --desired-count 1
```

---

## GCP

### 0. Preparar el entorno

**Login y elegir el proyecto**
```bash
gcloud auth login
```
*(si `gcloud` no está instalado, o si cualquier comando falla con `certificate verify failed`, ver apéndice — proxy corporativo)*

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

**Confirmar facturación**
```bash
gcloud billing projects describe <TU_PROJECT_ID>
```
Busca `billingEnabled: true`. Si dice `false`: `https://console.cloud.google.com/billing/linkedaccount?project=<TU_PROJECT_ID>`
*(si venías de un Free Trial y ya se convirtió a cuenta de pago, es normal e irreversible — el crédito no usado se sigue consumiendo primero de todas formas)*

**Habilitar las APIs necesarias**
```bash
gcloud services enable \
  artifactregistry.googleapis.com \
  run.googleapis.com \
  serviceusage.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project=<TU_PROJECT_ID>
```
Espera 30-60 segundos — la activación tarda en propagarse.

**Autenticar Terraform (cuenta de servicio)**

`gcloud auth login` autentica el CLI, pero **Terraform necesita sus propias credenciales** — son dos mecanismos separados. `gcloud auth application-default login` suele fallar en redes corporativas (redirect a `localhost` bloqueado por el proxy). El camino confiable:
```bash
gcloud iam service-accounts create terraform-otel-lab --display-name="Terraform OTel Lab" --project=<TU_PROJECT_ID>

gcloud projects add-iam-policy-binding <TU_PROJECT_ID> --member="serviceAccount:terraform-otel-lab@<TU_PROJECT_ID>.iam.gserviceaccount.com" --role="roles/run.admin"
gcloud projects add-iam-policy-binding <TU_PROJECT_ID> --member="serviceAccount:terraform-otel-lab@<TU_PROJECT_ID>.iam.gserviceaccount.com" --role="roles/iam.serviceAccountUser"
gcloud projects add-iam-policy-binding <TU_PROJECT_ID> --member="serviceAccount:terraform-otel-lab@<TU_PROJECT_ID>.iam.gserviceaccount.com" --role="roles/artifactregistry.reader"
gcloud projects add-iam-policy-binding <TU_PROJECT_ID> --member="serviceAccount:terraform-otel-lab@<TU_PROJECT_ID>.iam.gserviceaccount.com" --role="roles/serviceusage.serviceUsageAdmin"

gcloud iam service-accounts keys create ~/terraform-otel-lab-key.json --iam-account=terraform-otel-lab@<TU_PROJECT_ID>.iam.gserviceaccount.com

export GOOGLE_APPLICATION_CREDENTIALS="/c/Users/<tu_usuario>/terraform-otel-lab-key.json"
```
Terraform detecta esa variable automáticamente. La clave `.json` es sensible — ya está en `.gitignore`.

### 1. Imagen (repo + tag + push)

Es la misma imagen `otel-collector` que ya construiste en el Paso 0 — aquí solo se crea el repositorio de GCP y se sube una copia, no hay que reconstruirla:
```bash
gcloud artifacts repositories create observability \
  --repository-format=docker --location=us-central1 \
  --description="Imagenes del lab de observabilidad" \
  --project=<TU_PROJECT_ID>

gcloud auth configure-docker us-central1-docker.pkg.dev

docker tag otel-collector:latest us-central1-docker.pkg.dev/<TU_PROJECT_ID>/observability/otel-collector:latest
docker push us-central1-docker.pkg.dev/<TU_PROJECT_ID>/observability/otel-collector:latest
```
*(si Docker Desktop no está corriendo, `docker tag`/`push` fallan con un error de "pipe"/conexión — ábrelo y reintenta)*

### 2. Desplegar con Terraform

Jaeger y Prometheus ya están corriendo en AWS — el Collector de GCP le exporta a cada uno directamente, sin pasar por el Collector de AWS. Aquí no hay clúster, VPC ni subnets que crear.
```bash
cd terraform/gcp
terraform init
terraform apply \
  -var="project_id=<TU_PROJECT_ID>" \
  -var="collector_image=us-central1-docker.pkg.dev/<TU_PROJECT_ID>/observability/otel-collector:latest" \
  -var="aws_jaeger_public_ip=<IP_DE_JAEGER>" \
  -var="aws_prometheus_public_ip=<IP_DE_PROMETHEUS>"
```
Ambas IPs salen de la sección de AWS.

*(si falla con "repository not found", el repo del paso 1 no quedó en el mismo proyecto que `project_id`. Si falla `google_cloud_run_v2_service_iam_member` de acceso público, puede ser una política organizacional restringiendo `allUsers` — poco probable en cuenta personal)*

```bash
terraform output collector_url
```
Cloud Run da una URL HTTPS (`https://otel-collector-xxxxx-uc.a.run.app`), sin puerto explícito — enruta al receiver **HTTP** de OTLP (equivalente al `:4318` de AWS). Los microservicios de GCP deben mandar su OTLP ahí **con TLS habilitado**.

### 3. Probar manualmente con `curl`

Mismo patrón que en AWS, pero contra la URL de Cloud Run — sin puerto, con `--cacert` si tu red tiene inspección SSL corporativa (ver apéndice):
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
Revisa en **Jaeger UI** (`http://<IP_JAEGER>:16686`) — cambia el desplegable "Service" de `jaeger-all-in-one` (Jaeger monitoreándose a sí mismo) a `prueba-manual-gcp`.
```bash
NOW=$(date +%s%N)
curl -i --cacert "/c/Users/<tu_usuario>/aws-ca-bundle.pem" -X POST <TU_COLLECTOR_URL>/v1/metrics \
  -H "Content-Type: application/json" \
  -d "{\"resourceMetrics\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"prueba-manual-gcp\"}}]},\"scopeMetrics\":[{\"metrics\":[{\"name\":\"prueba_metrica_gcp\",\"gauge\":{\"dataPoints\":[{\"asDouble\":77,\"timeUnixNano\":\"$NOW\"}]}}]}]}]}"
```
Revisa en **Prometheus** — busca `prueba_metrica_gcp`, o para ver ambas nubes juntas: `up{cloud_provider="gcp"}` y `up{cloud_provider="aws"}`.

---

## Validar el pipeline completo (resumen)
- Trazas de AWS → consola de **X-Ray** (`us-east-1`).
- Trazas de GCP → **Jaeger UI** (`http://<IP_JAEGER>:16686`), filtrando por servicio.
- Métricas de ambas nubes → **Prometheus** (`http://<IP_PROMETHEUS>:9090`), un solo backend compartido.
- Logs de AWS → **CloudWatch**. Logs de GCP → **Cloud Logging**.
- Healthcheck del Collector de AWS: `GET http://<IP_COLLECTOR>:13133/`. El de GCP no es accesible públicamente — revisa el estado del servicio en la consola de Cloud Run.

## Pendiente para el reporte técnico
- [ ] Capturas del healthcheck del Collector de AWS.
- [ ] Captura de la consola de AWS X-Ray con trazas de los microservicios de AWS.
- [ ] Captura de Jaeger UI con trazas de los microservicios de GCP.
- [ ] Captura de Prometheus mostrando métricas etiquetadas `cloud.provider=aws` y `cloud.provider=gcp`.
- [ ] Explicación breve de por qué las trazas se dividen así (Jaeger para GCP, X-Ray para AWS, según la actividad) mientras las métricas quedan centralizadas en un solo Prometheus.
- [ ] Diagrama actualizado del pipeline (4 servicios en AWS + Cloud Run en GCP).
- [ ] Captura del `terraform apply` exitoso en ambas nubes.

## Limpieza (evitar gastar créditos de más)
```bash
cd terraform/aws && terraform destroy
cd ../gcp && terraform destroy
```

---

## Apéndice — Problemas ya resueltos (para no repetir la investigación)

### Error SSL: `certificate verify failed` (aws-cli)
Proxy corporativo con inspección SSL. 1) Exporta el certificado raíz del proxy desde el navegador (candado → ver certificado → Exportar → Base-64 X.509). 2) Descarga https://curl.se/ca/cacert.pem, pega el certificado del proxy al final, guarda como `aws-ca-bundle.pem`. 3) `export AWS_CA_BUNDLE="/c/Users/<tu_usuario>/aws-ca-bundle.pem"` (agrégalo a `~/.bashrc`).

### `gcloud` + certificado corporativo: `certificate verify failed`
Mismo proxy, `gcloud` no usa `AWS_CA_BUNDLE` — usa su propia config, reutilizando el mismo archivo:
```bash
gcloud config set core/custom_ca_certs_file "/c/Users/<tu_usuario>/aws-ca-bundle.pem"
```

### `curl` directo a HTTPS también falla con el mismo error SSL
Solo pasa contra HTTPS (por eso no lo viste probando contra AWS, que expone HTTP plano) — sí te pasa contra Cloud Run.
```bash
export CURL_CA_BUNDLE="/c/Users/<tu_usuario>/aws-ca-bundle.pem"
```
O puntual: `curl --cacert "/c/Users/<tu_usuario>/aws-ca-bundle.pem" ...`

### `docker push` a ECR falla con `denied: Your authorization token has expired`
El login de Docker a ECR expira cada ~12h. Repite: `aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com`

### `service-a` no arranca con `ModuleNotFoundError: No module named 'pkg_resources'`
`opentelemetry-instrumentation` (base de `-fastapi` y `-requests`) importa `pkg_resources`, que viene de `setuptools` — no de Python. `pip` moderno y `python:3.12-slim` no lo instalan solo. Solución: agregar `setuptools` explícito al `requirements.txt`.

### Error `InvalidClientTokenId`
El perfil `default` de AWS CLI tiene una Access Key inválida. Usa el perfil con nombre que sí funciona: `export AWS_PROFILE=<tu-perfil-bueno>`

### El repositorio de ECR/Artifact Registry se crea fuera de Terraform, a propósito
Evita el problema de "quién lo crea primero". Terraform solo lo referencia (`data` source), nunca lo crea ni lo destruye.

### El Collector crashea con `cannot resolve the configuration: retrieved value (type=string) cannot be used as a Conf`
Causa: una variable `${env:VAR}` como elemento suelto dentro de una lista YAML, en vez de valor completo de un campo. Solución: dos archivos de config completos (uno por nube), seleccionados por `command`/`args` desde Terraform.

Para diagnosticar sin gastar en despliegues: reprodúcelo en local con `docker run`. Si el log sale cortado, usa `docker run -d --name debug ... && docker logs debug` en vez de `--rm`.

### El Collector no arranca con `invalid configuration: exporters::<algo>: '<campo>' must be set`
El Collector valida **todos** los exporters declarados, incluso los no usados en ningún pipeline. Solución: cada config solo declara los exporters que esa nube realmente usa.

### Las peticiones a Cloud Run responden con HTTP 415
Cloud Run solo expone un puerto. `4317`/`h2c` es gRPC; nuestros `curl` mandan JSON por HTTP/1.1, que necesita `4318`. Solución: exponer `4318` en `terraform/gcp/main.tf`.

### `gcloud projects create` falla con "exceeded your allotted project quota"
Ya cubierto en GCP → Paso 0 — usa el proyecto por defecto.

### `terraform apply` en GCP falla con "could not find default credentials"
Ya cubierto en GCP → Paso 0 — usa la cuenta de servicio.

### Una traza de prueba llega al Collector (`partialSuccess`) pero no aparece en X-Ray
El formato del `traceId` — ver AWS → Paso 3.

### El tag `latest` no dispara redeploy automático en ECS
Fuerza el redeploy manualmente con `--force-new-deployment` (ver AWS → Paso 2).

### El Collector crashea con `listen tcp 0.0.0.0:4317: bind: address already in use`
Pasaba cuando Jaeger compartía tarea con el Collector (ya no aplica — cada uno tiene su propia tarea/ENI). Se deja documentado por si vuelves a compartir tareas por costo.
