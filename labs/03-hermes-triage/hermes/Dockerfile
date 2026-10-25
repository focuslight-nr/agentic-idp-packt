FROM python:3.12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Pinned 2026-10-25. A moving `main` install script can break the image.
ARG HERMES_REF=d05095663342556788cf2a198bfa7844cc7968ab
RUN curl -fsSL "https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_REF}/scripts/install.sh" | bash \
 && mkdir -p /app/runbooks
ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /app
COPY alert_bridge.py triage-prompt.md /app/

EXPOSE 8080
CMD ["python", "/app/alert_bridge.py"]
