"""
service-a
---------
Punto de entrada de una "orden". Recibe la petición del cliente
y llama a service-b para que la procese (dependencia HTTP).

Nota: esta es una base funcional simple. La configuración fina del
OTel Collector, sampling, y semantic conventions se ajustará más
adelante junto con el equipo (Fase 2 en adelante del laboratorio).
"""

import os
import logging

import requests
from fastapi import FastAPI, HTTPException

from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter

trace.set_tracer_provider(TracerProvider())
trace.get_tracer_provider().add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))

# --- Logging estructurado básico (se refinará a JSON con trace_id en Fase 1) ---
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("service-a")

app = FastAPI(title="service-a")

# --- Auto-instrumentación OTel (HTTP entrante y saliente) ---
FastAPIInstrumentor.instrument_app(app)
RequestsInstrumentor().instrument()

tracer = trace.get_tracer("service-a")

SERVICE_B_URL = os.getenv("SERVICE_B_URL", "http://localhost:8001")


@app.get("/health")
def health():
    return {"status": "ok", "service": "service-a"}


@app.post("/order")
def create_order(order: dict):
    """
    Endpoint principal: recibe una orden y la envía a service-b
    para su procesamiento. Este es el flujo que usaremos luego
    para validar la propagación de trace_id entre servicios.
    """
    # Custom span para lógica de negocio (más allá de la auto-instrumentación HTTP)
    with tracer.start_as_current_span("validate_order") as span:
        if "item" not in order:
            span.set_attribute("order.valid", False)
            raise HTTPException(status_code=400, detail="El campo 'item' es requerido")
        span.set_attribute("order.valid", True)
        span.set_attribute("order.item", order.get("item"))

    logger.info(f"Orden recibida, enviando a service-b: {order}")

    try:
        response = requests.post(f"{SERVICE_B_URL}/process", json=order, timeout=5)
        response.raise_for_status()
    except requests.RequestException as e:
        logger.error(f"Error llamando a service-b: {e}")
        raise HTTPException(status_code=502, detail="service-b no disponible")

    return response.json()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
