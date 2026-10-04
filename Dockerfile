# ---------- Stage 1: build the dashboard SPA (React + TanStack Router) ----------
FROM node:22-alpine AS spa
WORKDIR /spa
# Use a registry mirror reachable from CN networks when the default is slow.
RUN npm config set registry https://registry.npmmirror.com --location=global || true
COPY apps/janus_dashboard/spa/package.json apps/janus_dashboard/spa/package-lock.json* ./
RUN npm ci --no-audit --no-fund || npm install --no-audit --no-fund
COPY apps/janus_dashboard/spa/tsconfig.json apps/janus_dashboard/spa/vite.config.ts apps/janus_dashboard/spa/index.html ./
COPY apps/janus_dashboard/spa/public ./public
COPY apps/janus_dashboard/spa/src ./src
RUN npm run build

# ---------- Stage 2: compile the Erlang release ----------
FROM erlang:27-alpine AS build
WORKDIR /app
RUN sed -i 's#https://dl-cdn.alpinelinux.org#https://mirrors.aliyun.com#g' /etc/apk/repositories \
    && apk add --no-cache git build-base
COPY rebar.config rebar.lock* ./
COPY apps apps
COPY config config
# The built SPA lands in priv/www so the release ships it.
COPY --from=spa /spa/dist apps/janus_dashboard/priv/www/
COPY rebar3 rebar3
RUN chmod +x rebar3 && ./rebar3 as prod release

# ---------- Stage 3: runtime ----------
# Same base as build so OpenSSL matches the crypto NIF / ERTS
FROM erlang:27-alpine
WORKDIR /opt/janus
COPY --from=build /app/_build/prod/rel/janus ./
RUN mkdir -p /var/lib/janus &&     addgroup -S janus && adduser -S janus -G janus &&     chown -R janus:janus /opt/janus /var/lib/janus
USER janus
ENV JANUS_SQLITE_PATH=/var/lib/janus/janus.db
# 8080 = data plane, 8090 = dashboard plane (bind to loopback or put Caddy in front)
EXPOSE 8080 8090
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/healthz || wget -qO- http://127.0.0.1:8090/healthz || exit 1
CMD ["bin/janus", "foreground"]
