# Fase 2 — OTel Collector (Luis)

## Qué incluye este paquete
- `otel-collector-config-aws.yaml` / `otel-collector-config-gcp.yaml`: mismo pipeline, difieren solo en el exporter de logs (`awscloudwatchlogs` vs `googlecloud`). Las dos quedan horneadas en la **misma imagen** — Terraform le dice a cada despliegue cuál cargar (vía `command`/`args`), no una variable de entorno dentro del YAML (eso causó un crash real, ver el apéndice).
- `Dockerfile`: imagen basada en `otel-collector-contrib`, con las dos configs incluidas.
- `terraform/aws/`: ECR (referenciado, se crea a mano), log groups, IAM, cluster ECS, security group, y una Task Definition con 3 contenedores (Collector + Jaeger + Prometheus) en la misma tarea.
- `terraform/gcp/`: Artifact Registry, namespace y Deployment/Service del Collector en GKE (le exporta a Jaeger/Prometheus, que viven en AWS — no se duplican en GCP).

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
`<ACCOUNT_ID>` sale de `aws sts get-caller-identity`.

**3. Desplegar**
```bash
cd terraform/aws
terraform init
terraform apply -var="collector_image=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/otel-collector:latest"
```
Esto crea: log groups, roles IAM, cluster ECS, security group (4317-4318, 13133, 16686 Jaeger UI, 9090 Prometheus UI), y la tarea con los 3 contenedores.

**4. Obtener la IP pública**
```bash
terraform output get_public_ip_command
# corre el comando que imprime, o:
aws ecs list-tasks --cluster otel-lab-cluster --service-name otel-collector
```
Con la IP: Jaeger en `http://<IP>:16686`, Prometheus en `http://<IP>:9090`, healthcheck del Collector en `http://<IP>:13133/`.

**5. Si haces cambios y vuelves a subir la imagen al mismo tag `latest`**
El tag mutable no siempre dispara un redeploy automático en Terraform. Fuerza uno:
```bash
aws ecs update-service --cluster otel-lab-cluster --service otel-collector --force-new-deployment
```

**6. Pausar sin destruir infraestructura** (mientras depuras algo, para no seguir pagando)
```bash
aws ecs update-service --cluster otel-lab-cluster --service otel-collector --desired-count 0
# para reanudar: --desired-count 1
```

---

## GCP

**1. Crear el repositorio en Artifact Registry** (una vez, si no existe)
```bash
gcloud auth login
gcloud config set project <TU_PROJECT_ID>
gcloud artifacts repositories create observability \
  --repository-format=docker --location=us-central1 \
  --description="Imágenes del lab de observabilidad"
gcloud auth configure-docker us-central1-docker.pkg.dev
```

**2. Tag y push** (misma imagen del Paso 0)
```bash
docker tag otel-collector:latest us-central1-docker.pkg.dev/<TU_PROJECT_ID>/observability/otel-collector:latest
docker push us-central1-docker.pkg.dev/<TU_PROJECT_ID>/observability/otel-collector:latest
```

**3. Desplegar**

Jaeger y Prometheus ya están corriendo en AWS con IP pública — el Collector de GCP les exporta ahí directamente, no se duplican en GCP.
```bash
cd terraform/gcp
terraform init
terraform apply \
  -var="project_id=<TU_PROJECT_ID>" \
  -var="collector_image=us-central1-docker.pkg.dev/<TU_PROJECT_ID>/observability/otel-collector:latest" \
  -var="aws_collector_public_ip=<IP_PUBLICA_DE_AWS>"
```
`<IP_PUBLICA_DE_AWS>` es la misma que sacaste con `terraform output get_public_ip_command` en la sección de AWS.

---

## Validar el pipeline completo
- Apunta el exporter OTLP de service-a/service-b (Fase 1, de Astrid) al Collector correspondiente en cada nube.
- Healthcheck: `GET http://<collector>:13133/` (en cada Collector, AWS y GCP).
- Jaeger UI (solo existe en AWS): trazas etiquetadas con `cloud.provider=aws` **y** `cloud.provider=gcp` — así confirmas que ambos Collectors le están exportando al mismo Jaeger.
- Prometheus (solo existe en AWS): métricas de ambos Collectors.
- Logs: CloudWatch (Collector de AWS) y Cloud Logging (Collector de GCP).

## Limpieza (evitar gastar créditos de más)
```bash
cd terraform/aws && terraform destroy
cd ../gcp && terraform destroy
```

## Pendiente para el reporte técnico
- [ ] Capturas del healthcheck de ambos Collectors.
- [ ] Captura de Jaeger UI mostrando trazas de las dos nubes.
- [ ] Explicación breve de las decisiones de diseño (una imagen para ambas nubes, Jaeger/Prometheus en AWS mientras se resuelve acceso a GCP).
- [ ] Diagrama actualizado del pipeline.
- [ ] Captura del `terraform apply` exitoso en ambas nubes.

---

## Apéndice — Problemas ya resueltos (para no repetir la investigación)

### Error SSL: `certificate verify failed: unable to get local issuer certificate`
Proxy corporativo con inspección SSL (Zscaler, Netskope, etc.). `aws-cli` no confía en su certificado por defecto.
1. Exporta el certificado raíz del proxy desde el navegador (candado → ver certificado → Exportar → Base-64 X.509).
2. Descarga https://curl.se/ca/cacert.pem, pega el certificado del proxy al final, guarda como `aws-ca-bundle.pem`.
3. `export AWS_CA_BUNDLE="/c/Users/<tu_usuario>/aws-ca-bundle.pem"` (agrégalo a `~/.bashrc`).

### Error `InvalidClientTokenId`
El perfil `default` de AWS CLI tiene una Access Key inválida. Si VS Code muestra "Connected" con un perfil con nombre, usa ese:
```bash
export AWS_PROFILE=<tu-perfil-bueno>
```

### El repositorio de ECR/Artifact Registry se crea fuera de Terraform, a propósito
Evita el problema de "quién lo crea primero" (necesitas el repo para el `docker push`, pero antes de tener nada que desplegar). Terraform solo lo referencia como recurso existente (`data` source), nunca lo crea ni lo destruye.

### El Collector crashea con `cannot resolve the configuration: retrieved value (type=string) cannot be used as a Conf`
Causa: una variable `${env:VAR}` usada como elemento suelto dentro de una lista YAML (ej. `exporters: [${env:LOG_EXPORTER}, debug]`) en vez de como valor completo de un campo. El resolver de OTel Collector la maneja distinto y falla. Solución adoptada en este repo: dos archivos de config completos (uno por nube) horneados en la misma imagen, seleccionados por `command`/`args` desde Terraform — nunca por una variable de entorno dentro del YAML.

Para diagnosticar este tipo de crash sin gastar en ciclos de despliegue: reprodúcelo en local con `docker run`. Si el proceso muere muy rápido y el log sale cortado, usa `docker run -d --name debug ... && docker logs debug` en vez de `--rm` en primer plano, para leer el buffer completo.

### El tag `latest` no dispara redeploy automático en ECS
Terraform compara el texto de la variable `collector_image`, no el contenido real de la imagen. Si reusas el tag `latest`, fuerza el redeploy manualmente (ver sección AWS, paso 5).

### El Collector crashea con `listen tcp 0.0.0.0:4317: bind: address already in use`
Causa: Jaeger, con `COLLECTOR_OTLP_ENABLED=true`, levanta su propio receptor OTLP en los mismos puertos por defecto que el Collector (4317/4318). Como Collector, Jaeger y Prometheus comparten red (misma ECS Task), chocan por el puerto.

Solución adoptada en este repo: mover el receptor OTLP de Jaeger a 5317/5318 con las env vars `COLLECTOR_OTLP_GRPC_HOST_PORT` / `COLLECTOR_OTLP_HTTP_HOST_PORT`, y apuntar `JAEGER_OTLP_ENDPOINT` del Collector a `localhost:5317` en vez de `localhost:4317`. Así el 4317/4318 "de cara afuera" (donde llegan los datos de service-a/service-b) quedan solo para el Collector.
