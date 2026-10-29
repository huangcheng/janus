FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY janus_judge/ ./janus_judge/
COPY testdata/ ./testdata/

RUN useradd --create-home --uid 10001 appuser \
    && mkdir -p /var/lib/janus-judge \
    && chown -R appuser:appuser /app /var/lib/janus-judge
USER appuser

ENV PYTHONUNBUFFERED=1
EXPOSE 8191

# Loopback only (SPEC §5); share janus network in compose (network_mode: service:janus).
CMD ["uvicorn", "janus_judge.app:app", "--host", "127.0.0.1", "--port", "8191"]
