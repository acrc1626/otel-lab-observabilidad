terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

variable "project_id" {
  description = "ID del proyecto de GCP"
  type        = string
}

variable "region" {
  description = "Región de GCP"
  type        = string
  default     = "us-central1"
}

variable "collector_image" {
  description = "Imagen del Collector ya publicada en Artifact Registry (se sube con docker push, este módulo no la construye)"
  type        = string
}

variable "aws_jaeger_public_ip" {
  description = "IP pública de la tarea de Jaeger en AWS (terraform output get_jaeger_public_ip_command de terraform/aws). El Collector de GCP le exporta trazas directamente — Jaeger es la herramienta de trazas para GCP según la actividad, aunque físicamente corre como infraestructura en AWS."
  type        = string
}

variable "aws_prometheus_public_ip" {
  description = "IP pública de la tarea de Prometheus en AWS (terraform output get_prometheus_public_ip_command de terraform/aws). Backend de métricas centralizado, compartido con el Collector de AWS."
  type        = string
}

variable "service_b_image" {
  description = "Imagen de service-b ya publicada en Artifact Registry (docker build + push, este módulo no la construye)."
  type        = string
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# --- Habilitar las APIs necesarias (un proyecto nuevo las trae desactivadas por defecto) ---
resource "google_project_service" "artifactregistry" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "run" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

# --- Repositorio de imágenes: se crea a mano (gcloud artifacts repositories create),
# acá solo se referencia — mismo criterio que en AWS, evita el problema de "quién lo
# crea primero" (necesitas el repo para el push, pero antes de tener nada que desplegar).
data "google_artifact_registry_repository" "observability" {
  depends_on    = [google_project_service.artifactregistry]
  location      = var.region
  repository_id = "observability"
}

# --- El Collector, como servicio de Cloud Run (sin clúster, sin VPC que armar) ---
resource "google_cloud_run_v2_service" "otel_collector" {
  depends_on = [google_project_service.run]
  name       = "otel-collector"
  location   = var.region
  ingress    = "INGRESS_TRAFFIC_ALL" # accesible desde internet, igual que hicimos en AWS para el lab

  template {
    # Fijo en 1 instancia siempre activa: el Collector debe estar escuchando
    # permanentemente (OTLP/gRPC), no es un patrón de "responde y se apaga"
    # como una API REST típica en Cloud Run.
    scaling {
      min_instance_count = 1
      max_instance_count = 1
    }

    containers {
      image = var.collector_image
      # Misma imagen que en AWS; le decimos explícitamente que cargue la config de GCP.
      args = ["--config=/etc/otel-collector-config-gcp.yaml"]

      # Cloud Run solo enruta tráfico externo a UN puerto por servicio (a diferencia
      # de Fargate, que puede exponer varios). Elegimos 4318 (HTTP/JSON) en vez de
      # 4317 (gRPC) — nuestras pruebas con curl mandan JSON por HTTP/1.1 normal, que
      # necesita el receiver HTTP, no el gRPC. Si tus microservicios usan el SDK de
      # OTel configurado específicamente para gRPC, cambia esto de vuelta a 4317
      # (con name="h2c") y ajusta el exporter de tu app para hablar HTTP en su lugar.
      ports {
        name           = "http1"
        container_port = 4318
      }

      env {
        name  = "CLOUD_PROVIDER"
        value = "gcp"
      }
      env {
        name  = "DEPLOYMENT_ENV"
        value = "lab"
      }
      # Jaeger y Prometheus corren cada uno en su propia tarea de ECS en AWS —
      # el Collector de GCP le exporta a cada uno directamente, sin pasar por
      # ningún otro Collector intermedio.
      env {
        name  = "JAEGER_OTLP_ENDPOINT"
        value = "${var.aws_jaeger_public_ip}:4317"
      }
      env {
        name  = "JAEGER_TLS_INSECURE"
        value = "true"
      }
      env {
        name  = "PROMETHEUS_REMOTE_WRITE_ENDPOINT"
        value = "http://${var.aws_prometheus_public_ip}:9090/api/v1/write"
      }
      env {
        name  = "PROMETHEUS_TLS_INSECURE"
        value = "true"
      }
      env {
        name  = "GCP_PROJECT_ID"
        value = var.project_id
      }

      # Chequeo TCP simple sobre el puerto principal (4318, el mismo que sirve
      # tráfico real) en vez de HTTP en el puerto secundario del healthcheck
      # (13133) — ese puerto secundario no resultó confiable dentro del sandbox
      # de Cloud Run, aunque funciona sin problema en ECS/Fargate.
      startup_probe {
        tcp_socket {
          port = 4318
        }
        initial_delay_seconds = 5
        timeout_seconds        = 3
        period_seconds         = 5
        failure_threshold      = 12
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
    }
  }
}

# Cloud Run exige acceso autenticado por defecto; lo abrimos para el lab
# (mismo criterio que "abierto a internet solo para el lab" que usamos en AWS).
resource "google_cloud_run_v2_service_iam_member" "public_access" {
  location = google_cloud_run_v2_service.otel_collector.location
  name     = google_cloud_run_v2_service.otel_collector.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# --- service-b: el microservicio real que recibe la orden de service-a
# (en AWS) y la persiste en su DB local. Vive en GCP, y le exporta sus
# propias trazas/métricas al Collector de GCP (su nube), no cruza a AWS
# para eso — el cruce entre nubes ocurre a nivel de la llamada de negocio
# (service-a en AWS → service-b en GCP por HTTPS), no en la telemetría.
resource "google_cloud_run_v2_service" "service_b" {
  depends_on = [google_project_service.run]
  name       = "service-b"
  location   = var.region
  ingress    = "INGRESS_TRAFFIC_ALL" # service-a, en AWS, necesita alcanzarlo desde afuera

  template {
    containers {
      image = var.service_b_image

      ports {
        name           = "http1"
        container_port = 8001
      }

      env {
        # Le exporta al Collector de GCP (su propia nube) — referenciado
        # directo del recurso, no como variable, porque ambos viven en
        # este mismo módulo de Terraform.
        name  = "OTEL_EXPORTER_OTLP_ENDPOINT"
        value = google_cloud_run_v2_service.otel_collector.uri
      }

      # /health sí vive en el mismo puerto que sirve tráfico real (8001),
      # a diferencia del Collector — por eso aquí un http_get normal es
      # confiable (no tuvimos el problema del puerto secundario).
      startup_probe {
        http_get {
          path = "/health"
          port = 8001
        }
        initial_delay_seconds = 5
        timeout_seconds        = 3
        period_seconds         = 5
        failure_threshold      = 12
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "service_b_public_access" {
  location = google_cloud_run_v2_service.service_b.location
  name     = google_cloud_run_v2_service.service_b.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "service_b_url" {
  description = "URL pública HTTPS de service-b. Esta es la que va en SERVICE_B_URL del lado de AWS (service-a) — actualiza esa variable y vuelve a aplicar terraform/aws para completar la conexión cross-cloud."
  value       = google_cloud_run_v2_service.service_b.uri
}

output "artifact_registry_repo" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${data.google_artifact_registry_repository.observability.repository_id}"
}

output "collector_url" {
  description = "URL pública HTTPS del Collector en Cloud Run. Los microservicios de GCP mandan su OTLP acá (con TLS habilitado, a diferencia del endpoint de AWS que es TCP plano)."
  value       = google_cloud_run_v2_service.otel_collector.uri
}
