terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "collector_image" {
  description = "Imagen del Collector ya publicada en ECR (se sube con docker push, este módulo no la construye)"
  type        = string
}

# --- Autenticación: usa las credenciales de "aws configure" o variables AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY ---
provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

# --- Red: se descubre automáticamente, no hay que pasar subnet/SG a mano ---
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# --- Security group compartido por las 3 tareas (cada una tiene su propio ENI,
# así que no hay conflicto de puertos aunque todas usen el mismo SG) ---
resource "aws_security_group" "observability" {
  name        = "otel-observability-sg"
  description = "Puertos del Collector, Jaeger y Prometheus (lab)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "OTLP gRPC/HTTP - abierto a internet solo para el lab, no usar asi en produccion"
    from_port   = 4317
    to_port     = 4318
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Healthcheck del Collector - abierto a internet solo para el lab, no usar asi en produccion"
    from_port   = 13133
    to_port     = 13133
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Jaeger UI - abierto a internet solo para el lab, no usar asi en produccion"
    from_port   = 16686
    to_port     = 16686
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Prometheus UI y remote-write - abierto a internet solo para el lab, no usar asi en produccion"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "service-a (8000) y service-b (8001, para cuando exista) - solo para el lab"
    from_port   = 8000
    to_port     = 8001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Grafana UI - abierto a internet solo para el lab, no usar asi en produccion"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- Cluster ECS: se crea si no existe, no hay que crearlo a mano ---
resource "aws_ecs_cluster" "this" {
  name = "otel-lab-cluster"
}

# --- Namespace de Cloud Map para Service Connect: DNS privado dentro de la VPC.
# Con esto, "otel-collector.otel-lab.internal" siempre resuelve a la tarea
# actual del Collector, sin importar cuántas veces se recree — elimina el
# problema de tener que rastrear y volver a pasar la IP a mano cada vez.
resource "aws_service_discovery_private_dns_namespace" "otel_lab" {
  name = "otel-lab.internal"
  vpc  = data.aws_vpc.default.id
}

# --- Repositorio de imágenes: se crea a mano (aws ecr create-repository), acá solo se referencia ---
data "aws_ecr_repository" "otel_collector" {
  name = "otel-collector"
}

# --- Log groups (uno para el Collector, uno compartido para Jaeger/Prometheus) ---
resource "aws_cloudwatch_log_group" "collector_data" {
  name              = "/otel/collector"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "ecs_task_logs" {
  name              = "/ecs/otel-observability"
  retention_in_days = 14
}

# --- IAM: rol de ejecución, compartido por las 3 tareas (pull de imagen, logs) ---
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole-otel"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- IAM: rol de la tarea del Collector — CloudWatch Logs + X-Ray.
# Solo el Collector necesita este rol (llama a AWS APIs directamente);
# Jaeger y Prometheus no llaman a ninguna API de AWS, no necesitan task role propio.
resource "aws_iam_role" "otel_collector_task_role" {
  name = "otelCollectorTaskRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "otel_collector_task_policy" {
  name = "otel-collector-cloudwatch-logs"
  role = aws_iam_role.otel_collector_task_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.collector_data.arn}:*"
    }]
  })
}

# Permisos para que el exporter "awsxray" del Collector pueda mandar trazas a X-Ray.
resource "aws_iam_role_policy_attachment" "otel_collector_xray" {
  role       = aws_iam_role.otel_collector_task_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess"
}

# ============================================================
# Servicio 1: OTel Collector — recibe de los microservicios de AWS
# (y del Collector de GCP no, ver terraform/gcp: GCP le exporta
# directo a Jaeger/Prometheus, no a este Collector)
# ============================================================
resource "aws_ecs_task_definition" "otel_collector" {
  family                   = "otel-collector"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn             = aws_iam_role.otel_collector_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "otel-collector"
      image     = var.collector_image
      essential = true
      command   = ["--config=/etc/otel-collector-config-aws.yaml"]
      portMappings = [
        { containerPort = 4317, protocol = "tcp" },
        { containerPort = 4318, protocol = "tcp", name = "otlp-http" },
        { containerPort = 13133, protocol = "tcp" }
      ]
      environment = [
        { name = "CLOUD_PROVIDER", value = "aws" },
        { name = "DEPLOYMENT_ENV", value = "lab" },
        # DNS interno de Service Connect en vez de una IP que puede cambiar.
        { name = "PROMETHEUS_REMOTE_WRITE_ENDPOINT", value = "http://prometheus.otel-lab.internal:9090/api/v1/write" },
        { name = "PROMETHEUS_TLS_INSECURE", value = "true" },
        { name = "CLOUDWATCH_LOG_GROUP", value = aws_cloudwatch_log_group.collector_data.name },
        { name = "CLOUDWATCH_LOG_STREAM", value = "collector-aws" },
        { name = "AWS_REGION", value = var.region }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_task_logs.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "otel"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "otel_collector" {
  name            = "otel-collector"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.otel_collector.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.observability.id]
    assign_public_ip = true
  }

  # Servidor: se registra como "otel-collector.otel-lab.internal" para que
  # service-a lo encuentre. También actúa como cliente (sin bloque "service"
  # extra) para poder resolver "prometheus.otel-lab.internal" él mismo.
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_private_dns_namespace.otel_lab.arn

    service {
      port_name      = "otlp-http"
      discovery_name = "otel-collector"
      client_alias {
        port = 4318
      }
    }
  }
}

# ============================================================
# Servicio 2: Jaeger — standalone, propia tarea/ENI. Recibe trazas
# del Collector de GCP directamente (según la actividad, Jaeger es
# la herramienta de trazas asociada a GCP). Vive en AWS solo como
# infraestructura, no está atado a los microservicios de AWS.
# ============================================================
resource "aws_ecs_task_definition" "jaeger" {
  family                   = "jaeger"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  # Sin task_role_arn: Jaeger no llama a ninguna API de AWS por su cuenta.

  container_definitions = jsonencode([
    {
      name      = "jaeger"
      image     = "jaegertracing/all-in-one:1.60"
      essential = true
      portMappings = [
        { containerPort = 16686, protocol = "tcp" }, # UI
        { containerPort = 4317, protocol = "tcp" },  # OTLP gRPC — libre de conflicto, tarea propia
        { containerPort = 4318, protocol = "tcp" }   # OTLP HTTP
      ]
      environment = [
        { name = "COLLECTOR_OTLP_ENABLED", value = "true" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_task_logs.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "jaeger"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "jaeger" {
  name            = "jaeger"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.jaeger.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.observability.id]
    assign_public_ip = true
  }
}

# ============================================================
# Servicio 3: Prometheus — standalone, propia tarea/ENI. Backend
# de métricas centralizado y compartido: recibe remote_write tanto
# del Collector de AWS como del Collector de GCP.
# ============================================================
resource "aws_ecs_task_definition" "prometheus" {
  family                   = "prometheus"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "prometheus"
      image     = "prom/prometheus:latest"
      essential = true
      portMappings = [
        { containerPort = 9090, protocol = "tcp", name = "prom-http" }
      ]
      command = [
        "--config.file=/etc/prometheus/prometheus.yml",
        "--web.enable-remote-write-receiver"
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_task_logs.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "prometheus"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "prometheus" {
  name            = "prometheus"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.prometheus.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.observability.id]
    assign_public_ip = true
  }

  # Servidor: se registra como "prometheus.otel-lab.internal" para que el
  # Collector y Grafana lo encuentren sin necesitar su IP pública.
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_private_dns_namespace.otel_lab.arn

    service {
      port_name      = "prom-http"
      discovery_name = "prometheus"
      client_alias {
        port = 9090
      }
    }
  }
}

# ============================================================
# Servicio 4: service-a — el microservicio real de Astrid.
# Su código ya lee OTEL_EXPORTER_OTLP_ENDPOINT del entorno (no
# necesita ningún cambio), solo hay que dárselo al desplegar.
# ============================================================
resource "aws_ecs_task_definition" "service_a" {
  family                   = "service-a"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  # Sin task_role_arn: service-a no llama a ninguna API de AWS por su cuenta,
  # solo habla OTLP con el Collector y HTTP normal con service-b.

  container_definitions = jsonencode([
    {
      name      = "service-a"
      image     = var.service_a_image
      essential = true
      portMappings = [
        { containerPort = 8000, protocol = "tcp" }
      ]
      environment = [
        # DNS interno de Service Connect en vez de la IP pública del Collector,
        # que cambiaba cada vez que la tarea se recreaba.
        { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://otel-collector.otel-lab.internal:4318" },
        { name = "SERVICE_B_URL", value = var.service_b_url }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_task_logs.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "service-a"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "service_a" {
  name            = "service-a"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.service_a.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.observability.id]
    assign_public_ip = true
  }

  # Solo cliente: necesita resolver "otel-collector.otel-lab.internal", pero
  # nadie internamente necesita encontrar a service-a (nada de bloque "service").
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_private_dns_namespace.otel_lab.arn
  }
}

# ============================================================
# Servicio 5: Grafana — para consultar/visualizar Prometheus.
# Imagen oficial sin modificar, igual que Jaeger/Prometheus.
# El dashboard en sí (los 6 paneles que pide la actividad) es
# trabajo de Alex en la Fase 3 — esto solo deja Grafana desplegado
# y conectado, listo para que él lo use.
# ============================================================
resource "aws_ecs_task_definition" "grafana" {
  family                   = "grafana"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "grafana"
      image     = "grafana/grafana:latest"
      essential = true
      portMappings = [
        { containerPort = 3000, protocol = "tcp" }
      ]
      environment = [
        # Credenciales por defecto (admin/admin) — cámbialas al primer login.
        # Es un lab con security group abierto a internet, no dejes esto así
        # en un entorno real.
        { name = "GF_SECURITY_ADMIN_USER", value = "admin" },
        { name = "GF_SECURITY_ADMIN_PASSWORD", value = "admin" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_task_logs.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "grafana"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "grafana" {
  name            = "grafana"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.grafana.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.observability.id]
    assign_public_ip = true
  }

  # Solo cliente: para que el datasource de Prometheus en la UI de Grafana
  # pueda usar "http://prometheus.otel-lab.internal:9090" en vez de la IP
  # pública, que se rompía cada vez que Prometheus se recreaba.
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_private_dns_namespace.otel_lab.arn
  }
}

variable "service_a_image" {
  description = "Imagen de service-a ya publicada en ECR (docker build + push, este módulo no la construye)."
  type        = string
}

variable "service_b_url" {
  description = "URL de service-b. Placeholder hasta que ese servicio exista — actualízalo y vuelve a aplicar cuando esté desplegado."
  type        = string
  default     = "http://localhost:8001"
}

output "ecr_repository_url" {
  value = data.aws_ecr_repository.otel_collector.repository_url
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "get_collector_public_ip_command" {
  description = "IP pública de la tarea del Collector."
  value = "aws ecs describe-tasks --cluster ${aws_ecs_cluster.this.name} --tasks $(aws ecs list-tasks --cluster ${aws_ecs_cluster.this.name} --service-name otel-collector --query 'taskArns[0]' --output text) --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text | xargs -I{} aws ec2 describe-network-interfaces --network-interface-ids {} --query 'NetworkInterfaces[0].Association.PublicIp' --output text"
}

output "get_jaeger_public_ip_command" {
  description = "IP pública de la tarea de Jaeger. Esta es la que necesita GCP en su variable aws_jaeger_public_ip."
  value = "aws ecs describe-tasks --cluster ${aws_ecs_cluster.this.name} --tasks $(aws ecs list-tasks --cluster ${aws_ecs_cluster.this.name} --service-name jaeger --query 'taskArns[0]' --output text) --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text | xargs -I{} aws ec2 describe-network-interfaces --network-interface-ids {} --query 'NetworkInterfaces[0].Association.PublicIp' --output text"
}

output "get_prometheus_public_ip_command" {
  description = "IP pública de la tarea de Prometheus. Ya no la necesita este módulo (el Collector le habla por DNS interno de Service Connect) — solo hace falta para GCP (variable aws_prometheus_public_ip) y para que tú la consultes desde tu navegador."
  value = "aws ecs describe-tasks --cluster ${aws_ecs_cluster.this.name} --tasks $(aws ecs list-tasks --cluster ${aws_ecs_cluster.this.name} --service-name prometheus --query 'taskArns[0]' --output text) --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text | xargs -I{} aws ec2 describe-network-interfaces --network-interface-ids {} --query 'NetworkInterfaces[0].Association.PublicIp' --output text"
}

output "get_service_a_public_ip_command" {
  description = "IP pública de la tarea de service-a — úsala para pegarle a /health y /order desde afuera."
  value = "aws ecs describe-tasks --cluster ${aws_ecs_cluster.this.name} --tasks $(aws ecs list-tasks --cluster ${aws_ecs_cluster.this.name} --service-name service-a --query 'taskArns[0]' --output text) --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text | xargs -I{} aws ec2 describe-network-interfaces --network-interface-ids {} --query 'NetworkInterfaces[0].Association.PublicIp' --output text"
}

output "get_grafana_public_ip_command" {
  description = "IP pública de la tarea de Grafana."
  value = "aws ecs describe-tasks --cluster ${aws_ecs_cluster.this.name} --tasks $(aws ecs list-tasks --cluster ${aws_ecs_cluster.this.name} --service-name grafana --query 'taskArns[0]' --output text) --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text | xargs -I{} aws ec2 describe-network-interfaces --network-interface-ids {} --query 'NetworkInterfaces[0].Association.PublicIp' --output text"
}
