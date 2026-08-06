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

resource "aws_security_group" "otel_collector" {
  name        = "otel-collector-sg"
  description = "Permite OTLP (4317/4318), healthcheck (13133), Jaeger UI (16686) y Prometheus UI (9090)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "OTLP gRPC/HTTP - abierto a internet solo para el lab, no usar asi en produccion"
    from_port   = 4317
    to_port     = 4318
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Healthcheck - abierto a internet solo para el lab, no usar asi en produccion"
    from_port   = 13133
    to_port     = 13133
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Jaeger UI (abierto a internet solo para el lab, no usar asi en produccion)"
    from_port   = 16686
    to_port     = 16686
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Prometheus UI (abierto a internet solo para el lab, no usar asi en produccion)"
    from_port   = 9090
    to_port     = 9090
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

# --- Repositorio de imágenes: se crea a mano (aws ecr create-repository), acá solo se referencia ---
data "aws_ecr_repository" "otel_collector" {
  name = "otel-collector"
}

# --- 1. Log groups ---
resource "aws_cloudwatch_log_group" "collector_data" {
  name              = "/otel/collector"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "ecs_task_logs" {
  name              = "/ecs/otel-collector"
  retention_in_days = 14
}

# --- 2. IAM: rol de ejecución (pull de imagen, logs del propio ECS) ---
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

# --- 3. IAM: rol de la tarea (permisos para que el Collector escriba en CloudWatch Logs) ---
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

# --- 4. Task Definition: Collector + Jaeger + Prometheus en la misma tarea ---
# En awsvpc todos los contenedores comparten red, así que se hablan por localhost.
# Esto evita depender de un endpoint externo en GCP mientras resuelves ese acceso.
resource "aws_ecs_task_definition" "otel_collector" {
  family                   = "otel-collector"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024" # subido de 256 a 1024 porque ahora corren 3 contenedores
  memory                   = "2048" # subido de 512 a 2048 por la misma razón
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn             = aws_iam_role.otel_collector_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "otel-collector"
      image     = var.collector_image
      essential = true
      # Misma imagen que en GCP; le decimos explícitamente que cargue la config de AWS
      # (awscloudwatchlogs como exporter de logs) en vez de dejarlo al default del Dockerfile.
      command = ["--config=/etc/otel-collector-config-aws.yaml"]
      portMappings = [
        { containerPort = 4317, protocol = "tcp" },
        { containerPort = 4318, protocol = "tcp" },
        { containerPort = 13133, protocol = "tcp" }
      ]
      environment = [
        { name = "CLOUD_PROVIDER", value = "aws" },
        { name = "DEPLOYMENT_ENV", value = "lab" },
        { name = "JAEGER_OTLP_ENDPOINT", value = "localhost:5317" },
        { name = "JAEGER_TLS_INSECURE", value = "true" },
        { name = "PROMETHEUS_REMOTE_WRITE_ENDPOINT", value = "http://localhost:9090/api/v1/write" },
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
    },
    {
      # Jaeger, con COLLECTOR_OTLP_ENABLED=true, levanta su propio receptor OTLP —
      # por defecto en los MISMOS puertos que el Collector (4317/4318). Como comparten
      # red (misma tarea), eso choca ("address already in use"). Se mueve el de Jaeger
      # a 5317/5318 para que 4317/4318 queden libres para el Collector, que es el que
      # recibe tráfico de afuera (service-a/service-b).
      name      = "jaeger"
      image     = "jaegertracing/all-in-one:1.60"
      essential = true
      portMappings = [
        { containerPort = 16686, protocol = "tcp" } # UI, la única que necesita salir
      ]
      environment = [
        { name = "COLLECTOR_OTLP_ENABLED", value = "true" },
        { name = "COLLECTOR_OTLP_GRPC_HOST_PORT", value = ":5317" },
        { name = "COLLECTOR_OTLP_HTTP_HOST_PORT", value = ":5318" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_task_logs.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "jaeger"
        }
      }
    },
    {
      name      = "prometheus"
      image     = "prom/prometheus:latest"
      essential = true
      portMappings = [
        { containerPort = 9090, protocol = "tcp" }
      ]
      command = [
        "--config.file=/etc/prometheus/prometheus.yml",
        "--web.enable-remote-write-receiver" # necesario para que el Collector le haga push por remote_write
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

# --- 5. Service ---
resource "aws_ecs_service" "otel_collector" {
  name            = "otel-collector"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.otel_collector.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.otel_collector.id]
    assign_public_ip = true
  }
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

output "get_public_ip_command" {
  description = "Fargate asigna la IP pública en tiempo de ejecución, no es un valor fijo de Terraform. Corre esto después del apply para obtenerla."
  value = "aws ecs describe-tasks --cluster ${aws_ecs_cluster.this.name} --tasks $(aws ecs list-tasks --cluster ${aws_ecs_cluster.this.name} --service-name otel-collector --query 'taskArns[0]' --output text) --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text | xargs -I{} aws ec2 describe-network-interfaces --network-interface-ids {} --query 'NetworkInterfaces[0].Association.PublicIp' --output text"
}
