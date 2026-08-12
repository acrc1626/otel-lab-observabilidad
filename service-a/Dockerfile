FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

EXPOSE 8000

# OTEL_EXPORTER_OTLP_ENDPOINT y SERVICE_B_URL se pasan como env vars al desplegar
# (ver terraform/aws/main.tf) — el código ya los lee del entorno, no hace falta
# hornear ningún valor en la imagen.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
