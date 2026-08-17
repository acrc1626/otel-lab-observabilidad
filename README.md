# LAB: Pipeline OpenTelemetry End-to-End con Jaeger y Prometheus en AWS

**Observabilidad en Ambientes Productivos**
Maestría en Arquitectura de Software
Bogotá, agosto 2026

Alexander Caballero García · Astrid Carolina Rodríguez · Brian Maldonado · Luis Alberto Rojas

---

# OTel Lab — Pipeline de Observabilidad End-to-End Cross-Cloud

## 🎯 Qué es esto

Un pipeline de observabilidad completo con OpenTelemetry sobre dos microservicios con dependencia real entre sí, desplegados en **dos proveedores cloud distintos**:

- **service-a** → AWS (ECS Fargate) — recibe y valida una orden
- **service-b** → GCP (Cloud Run) — procesa la orden y la persiste en base de datos

`service-a` llama a `service-b` cruzando de nube (AWS → GCP) vía HTTPS, permitiendo validar la propagación real de contexto de trazabilidad entre proveedores distintos.

## 🏗️ Arquitectura

**En AWS** (ECS Fargate, 5 servicios):
- `otel-collector`, `jaeger`, `prometheus`, `grafana` — consolidados en una misma tarea
- `service-a` — servicio independiente, se comunica con el Collector y Prometheus vía Service Connect (DNS interno)

**En GCP** (Cloud Run, 2 servicios):
- `otel-collector` (segundo Collector, config propia)
- `service-b`

Ambos Collectors exportan hacia el mismo backend centralizado (**Jaeger y Prometheus, alojados en AWS**), consolidando la visibilidad de ambas nubes en un solo punto de observación.

## 📁 Estructura del repositorio

```
otel-lab/
├── otl-collector/
│   ├── Dockerfile
│   ├── otel-collector-config-aws.yaml
│   ├── otel-collector-config-gcp.yaml
│   ├── README.md
│   └── terraform/
│       ├── aws/     # Cluster ECS, service-a, Security Group, IAM, logs
│       └── gcp/     # Cloud Run: Collector + service-b
├── service-a/
│   ├── main.py      # Soporta ENABLE_OTEL=false para el benchmark
│   ├── Dockerfile
│   └── requirements.txt
├── service-b/
│   ├── main.py      # Soporta ENABLE_OTEL=false para el benchmark
│   ├── Dockerfile
│   └── requirements.txt
├── benchmark.py      # Script de carga con medición de CPU/memoria (Fase 4)
└── evidencias/        # Capturas de pantalla (Figuras del reporte)
```

## 🚀 Cómo correr los microservicios localmente

```powershell
# Terminal 1 — service-b
cd service-b
$env:OTEL_SERVICE_NAME="service-b"
py -3.12 main.py

# Terminal 2 — service-a
cd service-a
$env:OTEL_SERVICE_NAME="service-a"
py -3.12 main.py

# Terminal 3 — probar el flujo
curl.exe -X POST http://localhost:8000/order -H "Content-Type: application/json" -d "{\"item\": \"laptop\"}"
```

Para correr **sin** instrumentación OTel (usado en el benchmark de overhead):
```powershell
$env:ENABLE_OTEL="false"
py -3.12 main.py
```

## 📊 Los 3 pilares de observabilidad

| Pilar | Cómo se implementó |
|---|---|
| **Trazas** | Auto-instrumentación (FastAPI, requests, SQLite) + spans manuales de negocio (`validate_order`, `persist_order`), exportadas vía OTLP |
| **Métricas** | Expuestas automáticamente por la auto-instrumentación de FastAPI, agregadas vía `remote_write` a un Prometheus centralizado |
| **Logs** | `LoggingHandler` del SDK de OTel, inyecta automáticamente `trace_id`/`span_id` en cada log |

## 🔍 Evidencia de la arquitectura cross-cloud

- Trazas con el mismo `trace_id` visibles tanto en **AWS X-Ray** como en **Jaeger** (ver `evidencias/`)
- Logs de `service-a` y `service-b` correlacionados por `trace_id` en CloudWatch Logs Insights
- Dashboard de Grafana con 6 paneles, mostrando métricas de ambos servicios

## 🐛 Hallazgos técnicos durante la integración

1. **Métricas de service-b no llegaban a Prometheus** — causa: intervalo de exportación por defecto (60s) incompatible con el escalado a cero de Cloud Run. Solución: `export_interval_millis=5000`.
2. **Logs sin correlación de trace_id** — causa: inconsistencia de protocolo (gRPC vs. HTTP) entre exportadores, y falta de `resource` en el `LoggerProvider`. Solución: unificar protocolo HTTP en los 3 pilares y agregar `resource=_resource`.

## 📈 Benchmark de overhead (Fase 4)

Script `benchmark.py`: 200 peticiones, 10 hilos concurrentes, comparando con/sin instrumentación, midiendo latencia (p50/p95/p99), throughput, CPU y memoria del proceso.

```powershell
python benchmark.py --url http://localhost:8000/order -n 200 -c 10 --tag "Con_OTel" --pid <PID>
```

**Resultado**: overhead despreciable en latencia (dentro del margen de ruido), overhead real y medible en recursos: +24.5% CPU promedio, +28.5% memoria promedio.

## 👥 Equipo

Alexander Caballero García · Astrid Carolina Rodríguez · Brian Maldonado · Luis Alberto Rojas

## 📄 Reporte completo

El reporte técnico completo (arquitectura, decisiones de diseño, hallazgos y análisis de overhead) está en la raíz del repositorio: `LAB_Pipeline_OpenTelemetry.pdf`
