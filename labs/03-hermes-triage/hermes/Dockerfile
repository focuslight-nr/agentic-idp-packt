FROM python:3.12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash \
 && mkdir -p /app/runbooks
ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /app
COPY alert_bridge.py triage-prompt.md /app/

EXPOSE 8080
CMD ["python", "/app/alert_bridge.py"]
