FROM otel/opentelemetry-collector-contrib:0.108.0

# Una sola imagen, dos variantes de config horneadas. El orquestador (ECS o Kubernetes)
# elige cuál usar sobreescribiendo "command"/"args" en el despliegue — no hay que construir
# ni publicar una imagen distinta por nube.
COPY otel-collector-config-aws.yaml /etc/otel-collector-config-aws.yaml
COPY otel-collector-config-gcp.yaml /etc/otel-collector-config-gcp.yaml

EXPOSE 4317 4318 13133

ENTRYPOINT ["/otelcol-contrib"]
# Default: AWS. El despliegue de GCP sobreescribe este CMD con --config=/etc/otel-collector-config-gcp.yaml
CMD ["--config=/etc/otel-collector-config-aws.yaml"]
