FROM erlang:27-alpine AS build
WORKDIR /app
RUN sed -i 's#https://dl-cdn.alpinelinux.org#https://mirrors.aliyun.com#g' /etc/apk/repositories \
    && apk add --no-cache git build-base
COPY rebar.config rebar.lock* ./
COPY apps apps
COPY config config
COPY rebar3 rebar3
RUN chmod +x rebar3 && ./rebar3 as prod release

# Same base as build so OpenSSL matches the crypto NIF / ERTS
FROM erlang:27-alpine
WORKDIR /opt/janus
COPY --from=build /app/_build/prod/rel/janus ./
RUN mkdir -p /var/lib/janus
ENV JANUS_SQLITE_PATH=/var/lib/janus/janus.db
EXPOSE 8080
CMD ["bin/janus", "foreground"]
