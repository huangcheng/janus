# Base images are overridable so anyone can build without the
# original operator's private registry: defaults are public Docker Hub
# images; CN builders pass e.g.
#   --build-arg PY_BASE=swr.cn-north-4.myhuaweicloud.com/<org>/base-python:3.12-slim
ARG PY_BASE=python:3.12-slim
ARG NODE_BASE=node:22-alpine
FROM ${PY_BASE} AS base
WORKDIR /app

# CN builders point these at domestic mirrors (SWR CI on tencent):
#   --build-arg PIP_INDEX=https://mirrors.aliyun.com/pypi/simple/
ARG PIP_INDEX
COPY pyproject.toml .
COPY app/ app/
RUN pip install --no-cache-dir ${PIP_INDEX:+-i ${PIP_INDEX}} .

# SPA build stage
FROM ${NODE_BASE} AS spa
WORKDIR /spa
#   --build-arg NPM_REGISTRY=https://registry.npmmirror.com
ARG NPM_REGISTRY
COPY spa/package.json spa/package-lock.json* ./
RUN npm ci --no-audit --no-fund ${NPM_REGISTRY:+--registry=${NPM_REGISTRY}} || npm install --no-audit --no-fund ${NPM_REGISTRY:+--registry=${NPM_REGISTRY}}
COPY spa/ .
# Build-time UI feature flags, e.g. --build-arg VITE_FLAG_MODEL_PRICES=1
ARG VITE_FLAG_MODEL_PRICES
# Public Turnstile sitekey (safe to bake into the SPA). Override via
# --build-arg when rotating widgets; empty disables the login widget.
ARG VITE_TURNSTILE_SITEKEY=0x4AAAAAAFd5g47sIgnudkiX
ENV VITE_TURNSTILE_SITEKEY=$VITE_TURNSTILE_SITEKEY
RUN npm run build

# Final image
FROM ${PY_BASE}
WORKDIR /app

COPY --from=base /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=base /app/app /app/app
COPY --from=base /app/pyproject.toml /app/
# Startup schema self-check reads this path; the image otherwise ships app/ only.
COPY docs/schemas/config-backup-v1.schema.json /app/docs/schemas/config-backup-v1.schema.json
COPY --from=spa /spa/dist /app/spa/dist

RUN addgroup --system janus && adduser --system janus --ingroup janus && \
    chown -R janus:janus /app
USER janus

ENV JANUS_DASHBOARD_PORT=8091
EXPOSE 8091

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD python -c "import os,urllib.request; p=os.environ.get('JANUS_DASHBOARD_PORT','8091'); urllib.request.urlopen(f'http://127.0.0.1:{p}/api/health')" || exit 1

CMD ["sh", "-c", "exec python -m uvicorn app.main:app --host 0.0.0.0 --port ${JANUS_DASHBOARD_PORT:-8091}"]
