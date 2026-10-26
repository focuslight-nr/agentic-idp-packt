FROM python:3.12-slim

RUN pip install --no-cache-dir ruamel.yaml==0.19.1
RUN useradd --create-home --uid 10001 bot
WORKDIR /app
COPY bot.py /app/

USER 10001
EXPOSE 8080
CMD ["python", "/app/bot.py"]
