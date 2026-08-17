"""
service-b
---------
Recibe la orden validada desde service-a y la persiste en base de
datos. Este servicio es el que ejercita el acceso a DB dentro del
pipeline (auto-instrumentation para sqlite3 + custom span de negocio).

Soporta la variable de entorno ENABLE_OTEL (true/false) para poder
correr el mismo servicio con y sin instrumentación OTel, usada en
el benchmark de overhead (Fase 4).
"""

import os
import sqlite3
import logging

from fastapi import FastAPI

from opentelemetry import trace, metrics

ENABLE_OTEL = os.getenv("ENABLE_OTEL", "true").lower() in ("true", "1", "yes")

if ENABLE_OTEL:
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
    from opentelemetry.instrumentation.sqlite3 import SQLite3Instrumentor
    from opentelemetry.sdk.resources import Resource, SERVICE_NAME
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.metrics import MeterProvider
    from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
    from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
    from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
    from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
    from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter

    _resource = Resource.create({SERVICE_NAME: "service-b"})

    # Endpoint leído desde OTEL_EXPORTER_OTLP_ENDPOINT
    trace.set_tracer_provider(TracerProvider(resource=_resource))
    trace.get_tracer_provider().add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))

    metrics.set_meter_provider(MeterProvider(
        resource=_resource,
        metric_readers=[PeriodicExportingMetricReader(OTLPMetricExporter(), export_interval_millis=5000)],
    ))

    logger_provider = LoggerProvider(resource=_resource)
    logger_provider.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter()))
    handler = LoggingHandler(level=logging.INFO, logger_provider=logger_provider)
    logging.getLogger().addHandler(handler)
    logging.getLogger().setLevel(logging.INFO)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("service-b")

app = FastAPI(title="service-b")

# --- Auto-instrumentación OTel (HTTP entrante y llamadas a sqlite3) ---
if ENABLE_OTEL:
    FastAPIInstrumentor.instrument_app(app)
    SQLite3Instrumentor().instrument()

# Cuando ENABLE_OTEL=false, trace.get_tracer() devuelve un tracer "no-op"
# por defecto de la API de OpenTelemetry (no falla, simplemente no genera
# ni exporta spans) — por eso el código de negocio no necesita ningún if.
tracer = trace.get_tracer("service-b")

DB_PATH = "orders.db"


def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        "CREATE TABLE IF NOT EXISTS orders (id INTEGER PRIMARY KEY, item TEXT, status TEXT)"
    )
    return conn


@app.get("/health")
def health():
    return {"status": "ok", "service": "service-b", "otel_enabled": ENABLE_OTEL}


@app.post("/process")
def process_order(order: dict):
    """
    Procesa la orden recibida desde service-a y la guarda en DB.
    El span 'persist_order' es un custom span de lógica de negocio,
    separado de la instrumentación automática de sqlite3.
    """
    item = order.get("item", "desconocido")

    with tracer.start_as_current_span("persist_order") as span:
        span.set_attribute("order.item", item)
        conn = get_db()
        cursor = conn.execute(
            "INSERT INTO orders (item, status) VALUES (?, ?)", (item, "processed")
        )
        conn.commit()
        order_id = cursor.lastrowid
        conn.close()
        span.set_attribute("order.id", order_id)

    logger.info(f"Orden procesada y guardada: id={order_id}, item={item}")

    return {"order_id": order_id, "item": item, "status": "processed"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8001)