FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

EXPOSE 8001

# OTEL_EXPORTER_OTLP_ENDPOINT se pasa como env var al desplegar (ver
# terraform/gcp/main.tf) — el código ya lo lee del entorno, no hace falta
# hornear ningún valor en la imagen.
#
# Nota: orders.db NO se copia a la imagen a propósito — el código crea la
# tabla sola (CREATE TABLE IF NOT EXISTS) al primer arranque. Como Cloud Run
# usa filesystem efímero, los datos no persisten entre reinicios/redeploys
# de todas formas — para algo real habría que usar una DB gestionada
# (Cloud SQL, etc.), como ya lo anota el propio comentario del código.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]
