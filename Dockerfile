# ---------- Stage 1: build the admin SPA (React + TanStack Router) ----------
FROM node:22-alpine AS spa
WORKDIR /spa
# Use a registry mirror reachable from CN networks when the default is slow.
RUN npm config set registry https://registry.npmmirror.com --location=global || true
COPY apps/janus_admin/spa/package.json ./
# No lockfile committed yet: install from the manifest.
RUN npm install --no-audit --no-fund
COPY apps/janus_admin/spa/tsconfig.json apps/janus_admin/spa/vite.config.ts apps/janus_admin/spa/index.html ./
COPY apps/janus_admin/spa/public ./public
COPY apps/janus_admin/spa/src ./src
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
COPY --from=spa /spa/dist apps/janus_admin/priv/www/
COPY rebar3 rebar3
RUN chmod +x rebar3 && ./rebar3 as prod release

# ---------- Stage 3: runtime ----------
# Same base as build so OpenSSL matches the crypto NIF / ERTS
FROM erlang:27-alpine
WORKDIR /opt/janus
COPY --from=build /app/_build/prod/rel/janus ./
RUN mkdir -p /var/lib/janus
ENV JANUS_SQLITE_PATH=/var/lib/janus/janus.db
# 8080 = data plane, 8090 = admin plane (bind to loopback or put Caddy in front)
EXPOSE 8080 8090
CMD ["bin/janus", "foreground"]
