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
