terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
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

variable "aws_collector_public_ip" {
  description = "IP pública de la tarea del Collector en AWS (terraform output get_public_ip_command de terraform/aws). El Collector de GCP le exporta trazas/métricas a este Collector, que a su vez reenvía a Jaeger/Prometheus (que corren internamente en esa misma tarea de AWS)."
  type        = string
}

# --- Autenticación: usa las credenciales activas de gcloud (gcloud auth application-default login) ---
provider "google" {
  project = var.project_id
  region  = var.region
}

# Terraform habla con el clúster GKE reutilizando el kubeconfig ya generado con:
# gcloud container clusters get-credentials <TU_CLUSTER> --region <REGION>
provider "kubernetes" {
  config_path = "~/.kube/config"
}

# --- 1. Repositorio de imágenes (reemplaza el paso manual "gcloud artifacts repositories create") ---
resource "google_artifact_registry_repository" "observability" {
  location      = var.region
  repository_id = "observability"
  description   = "Imágenes del lab de observabilidad"
  format        = "DOCKER"
}

# --- 2. Namespace ---
resource "kubernetes_namespace" "observability" {
  metadata {
    name = "observability"
  }
}

# --- 3. Deployment + Service del Collector ---
resource "kubernetes_deployment" "otel_collector" {
  metadata {
    name      = "otel-collector"
    namespace = kubernetes_namespace.observability.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "otel-collector" }
    }

    template {
      metadata {
        labels = { app = "otel-collector" }
      }

      spec {
        container {
          name  = "otel-collector"
          image = var.collector_image
          # Misma imagen que en AWS; le decimos explícitamente que cargue la config de GCP
          # (googlecloud como exporter de logs) en vez de la de AWS que trae por defecto.
          args  = ["--config=/etc/otel-collector-config-gcp.yaml"]

          port { container_port = 4317 }
          port { container_port = 4318 }
          port { container_port = 13133 }

          env { name = "CLOUD_PROVIDER"  value = "gcp" }
          env { name = "DEPLOYMENT_ENV"  value = "lab" }
          # Jaeger y Prometheus viven en AWS, dentro de la misma tarea del Collector —
          # se le manda todo al Collector público de AWS (puerto 4317), que reenvía
          # internamente a Jaeger/Prometheus. No se duplican en GCP.
          env { name = "JAEGER_OTLP_ENDPOINT" value = "${var.aws_collector_public_ip}:4317" }
          env { name = "JAEGER_TLS_INSECURE" value = "true" }
          env { name = "PROMETHEUS_REMOTE_WRITE_ENDPOINT" value = "http://${var.aws_collector_public_ip}:9090/api/v1/write" }
          env { name = "PROMETHEUS_TLS_INSECURE" value = "true" }
          env { name = "GCP_PROJECT_ID" value = var.project_id }

          readiness_probe {
            http_get {
              path = "/"
              port = 13133
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "otel_collector" {
  metadata {
    name      = "otel-collector"
    namespace = kubernetes_namespace.observability.metadata[0].name
  }
  spec {
    selector = { app = "otel-collector" }
    port {
      name        = "otlp-grpc"
      port        = 4317
      target_port = 4317
    }
    port {
      name        = "otlp-http"
      port        = 4318
      target_port = 4318
    }
    type = "ClusterIP"
  }
}

output "artifact_registry_repo" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.observability.repository_id}"
}
