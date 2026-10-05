# ---------- Stage T (test): prebuilt compile/eunit image ----------
# Slice C: one prebuilt image so Windows-local compile/eunit never
# touches dl-cdn.alpinelinux.org (default Alpine CDN hangs on China
# networks). apk goes through the Aliyun mirror, rebar3 lives outside
# /app so bind mounts cannot shadow the escript, and the hex package
# cache plus the erlfmt (rebar3 fmt) plugin are warmed at build time
# so a later named-volume _build mount forces no first-run hex fetch.
FROM erlang:27-alpine AS test
# APK mirror override: defaults to Aliyun; CI may override to the
# Alpine CDN via --build-arg if mirrors.aliyun.com is unreachable.
ARG APK_MIRROR=https://mirrors.aliyun.com
# Hex mirror override for China networks. rebar3 3.25 reads env
# HEX_CDN first, then HEX_MIRROR; the default is the official CDN
# (a no-op). At runtime `docker run -e HEX_CDN=...` still wins.
ARG HEX_MIRROR=
ENV HEX_MIRROR=${HEX_MIRROR:-https://repo.hex.pm}
WORKDIR /app
RUN sed -i "s#https://dl-cdn.alpinelinux.org#${APK_MIRROR}#g" /etc/apk/repositories \
    && apk add --no-cache git build-base
COPY rebar3 /usr/local/bin/rebar3
COPY rebar.config rebar.lock* ./
COPY apps apps
COPY config config
# Default profile compile bakes _build into the image; the hex cache
# under /root/.cache/rebar3 persists in the layer for mounted runs.
RUN chmod +x /usr/local/bin/rebar3 && rm -rf _build && rebar3 compile \
    && rebar3 plugins list > /dev/null

# ---------- Stage 1: compile the Erlang release ----------
FROM erlang:27-alpine AS build
WORKDIR /app
RUN sed -i 's#https://dl-cdn.alpinelinux.org#https://mirrors.aliyun.com#g' /etc/apk/repositories \
    && apk add --no-cache git build-base
COPY rebar.config rebar.lock* ./
COPY apps apps
COPY config config
COPY rebar3 rebar3
RUN chmod +x rebar3 && ./rebar3 as prod release

# ---------- Stage 2: runtime ----------
# Same base as build so OpenSSL matches the crypto NIF / ERTS
FROM erlang:27-alpine
WORKDIR /opt/janus
COPY --from=build /app/_build/prod/rel/janus ./
RUN mkdir -p /var/lib/janus &&     addgroup -S janus && adduser -S janus -G janus &&     chown -R janus:janus /opt/janus /var/lib/janus
USER janus
ENV JANUS_SQLITE_PATH=/var/lib/janus/janus.db
# 8080 = data plane, 8090 = admin stats plane (dashboard polls /stats)
EXPOSE 8080 8090
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/healthz || wget -qO- http://127.0.0.1:8090/healthz || exit 1
CMD ["bin/janus", "foreground"]
