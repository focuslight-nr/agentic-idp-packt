# The `orders` service: a tiny Python HTTP app that stands in for a real
# application. Built with `docker build` and loaded into the kind cluster with
# `kind load`, like every other image the labs use.
FROM python:3.12-slim

RUN useradd --create-home --uid 10001 orders
WORKDIR /app
COPY orders.py /app/orders.py

ENV PORT=8080
USER 10001
EXPOSE 8080

# The chart overrides this via `command`/`args` when a scenario wants to; by
# default it runs with no arguments and serves /healthz, /readyz, and /orders.
CMD ["python", "/app/orders.py"]
