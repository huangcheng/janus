# ---------- Stage T (tools): prebuilt compile/fmt image ----------
# Slice C: one prebuilt image so Windows-local compile/fmt never
# touches dl-cdn.alpinelinux.org (default Alpine CDN hangs on China
# networks). apk goes through the Aliyun mirror, rebar3 lives outside
# /app so bind mounts cannot shadow the escript, and the hex package
# cache plus the erlfmt (rebar3 fmt) plugin are warmed at build time
# so a later named-volume _build mount forces no first-run hex fetch.
# Base images are overridable so anyone can build without the
# original operator's private registry: defaults are public Docker Hub
# images; CN builders pass e.g.
#   --build-arg ERLANG_ALPINE_BASE=swr.cn-north-4.myhuaweicloud.com/<org>/base-erlang:27-alpine
ARG ERLANG_ALPINE_BASE=erlang:27-alpine
ARG ERLANG_GLIBC_BASE=erlang:27
FROM ${ERLANG_ALPINE_BASE} AS test
# APK mirror override: defaults to Aliyun; CI may override to the
# Alpine CDN via --build-arg if mirrors.aliyun.com is unreachable.
# A mirror can also be MID-SYNC: its APKINDEX lists a package the
# mirror has not published yet, and apk hard-fails with
# "musl-1.2.5-r13: package mentioned in index not found" — that broke
# the whole CI ship on 2026-10-22 (run 39769174453). Every apk install
# below therefore tries ${APK_MIRROR} first and falls back to the
# official CDN instead of failing the build.
ARG APK_MIRROR=https://mirrors.aliyun.com
# Hex mirror override for China networks. rebar3 3.25 reads env
# HEX_CDN first, then HEX_MIRROR; the default is the official CDN
# (a no-op). At runtime `docker run -e HEX_CDN=...` still wins.
ARG HEX_MIRROR=
ENV HEX_MIRROR=${HEX_MIRROR:-https://repo.hex.pm}
WORKDIR /app
RUN set -eux; \
    cp /etc/apk/repositories /tmp/apk-repos.orig; \
    for m in "${APK_MIRROR}" https://dl-cdn.alpinelinux.org; do \
      sed "s#https://dl-cdn.alpinelinux.org#${m}#g" /tmp/apk-repos.orig > /etc/apk/repositories; \
      if apk add --no-cache git build-base; then exit 0; fi; \
      echo "apk add via ${m} failed — trying the next mirror" >&2; \
    done; \
    echo "apk add failed via every mirror" >&2; exit 1
COPY rebar3 /usr/local/bin/rebar3
COPY rebar.config rebar.lock* ./
COPY apps apps
COPY config config
# Default profile compile bakes _build into the image; the hex cache
# under /root/.cache/rebar3 persists in the layer for mounted runs.
RUN chmod +x /usr/local/bin/rebar3 && rm -rf _build && rebar3 compile \
    && rebar3 plugins list > /dev/null

# ---------- Stage 1: compile the Erlang release ----------
FROM ${ERLANG_ALPINE_BASE} AS build
WORKDIR /app
# Same hex/apk mirrors as the test stage (China networks hang on defaults).
ARG APK_MIRROR=https://mirrors.aliyun.com
ARG HEX_MIRROR=
ARG HEX_CDN=
# rebar3 3.25 reads HEX_CDN first, then HEX_MIRROR.
ENV HEX_MIRROR=${HEX_MIRROR:-https://repo.hex.pm}
ENV HEX_CDN=${HEX_CDN:-${HEX_MIRROR}}
RUN set -eux; \
    cp /etc/apk/repositories /tmp/apk-repos.orig; \
    for m in "${APK_MIRROR}" https://dl-cdn.alpinelinux.org; do \
      sed "s#https://dl-cdn.alpinelinux.org#${m}#g" /tmp/apk-repos.orig > /etc/apk/repositories; \
      if apk add --no-cache git build-base; then exit 0; fi; \
      echo "apk add via ${m} failed — trying the next mirror" >&2; \
    done; \
    echo "apk add failed via every mirror" >&2; exit 1
COPY rebar.config rebar.lock* ./
COPY rebar3 rebar3
# Deps fetch gets its OWN layer: the release step must not refetch hex
# packages on every code change — the fetch is the flaky network path
# (2026-10-21 CI flakes all died mid-fetch inside `as prod release`).
# `as prod` matches the release profile so the cache is reused verbatim.
RUN chmod +x rebar3 && ./rebar3 as prod get-deps
COPY apps apps
COPY config config
# scripts/ feeds the relx overlay (renderer lib + bare wrapper ship
# inside the release tarball, spec 2026-10-15-bare-metal-deploy F5c).
COPY scripts scripts
RUN ./rebar3 as prod release

# ---------- Stage bare-builder: glibc release builder (B-D1/F3) ----------
# Builds the BARE-METAL gateway artifact (`rebar3 as prod release`,
# include_erts → tarball) for glibc hosts — see
# scripts/build_bare_release.sh. NEVER build the bare release in the
# alpine/musl stages above (a musl-linked ERTS will not load on glibc
# fleet nodes) and NEVER share the musl eunit `_build` cache — the
# bare builder runs with its OWN volume (janus-bare-ebin-otp27).
#
# DIGEST-PIN DUTY (F3): production release builds MUST run in the
# image pinned BY DIGEST in the operator inventory
# (JANUS_BARE_BUILDER=image@digest, with the glibc floor and
# libcrypto soname claims in JANUS_BARE_BUILDER_GLIBC /
# JANUS_BARE_BUILDER_LIBCRYPTO; scripts/switch_runtime.sh verifies
# the target node meets the floor BEFORE flipping). This floating
# `erlang:27` tag is dev/CI convenience only: today it tracks Debian
# bookworm (glibc 2.36, libcrypto.so.3 — a floor below every fleet
# node); if the tag moves to a newer Debian the floor rises and the
# OLDEST fleet node stops loading the release. The actual digest pin
# lives in deploy/inventory.env (see deploy/inventory.env.example),
# never in this Dockerfile.
FROM ${ERLANG_GLIBC_BASE} AS bare-builder
WORKDIR /app
# Hex mirror override, same ergonomics as the alpine stages.
ARG HEX_MIRROR=
ARG HEX_CDN=
ENV HEX_MIRROR=${HEX_MIRROR:-https://repo.hex.pm}
ENV HEX_CDN=${HEX_CDN:-${HEX_MIRROR}}
# Debian apt mirror, defaulting to Aliyun like the apk mirror above
# (deb.debian.org 502s on China networks; override --build-arg to
# keep distro defaults). Handles the deb822 debian.sources layout and
# the legacy sources.list, main + security suites.
ARG APT_MIRROR=https://mirrors.aliyun.com/debian
RUN if [ -n "$APT_MIRROR" ]; then \
        sed -i -E \
            -e "s#https?://deb.debian.org/debian-security#${APT_MIRROR}-security#g" \
            -e "s#https?://deb.debian.org/debian#${APT_MIRROR}#g" \
            /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list 2>/dev/null || true; \
    fi \
    && apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*
# Same pinned rebar3 escript as the alpine stages (the image's own
# rebar3 floats with the tag).
COPY rebar3 /usr/local/bin/rebar3
COPY rebar.config rebar.lock* ./
COPY apps apps
COPY config config
COPY scripts scripts
# Warm compile bakes the hex package cache into the layer so a later
# named-volume _build mount forces no first-run hex fetch (same
# rationale as the test stage).
RUN chmod +x /usr/local/bin/rebar3 && rm -rf _build && rebar3 compile \
    && rebar3 plugins list > /dev/null

# ---------- Stage 2: runtime ----------
# Same base as build so OpenSSL matches the crypto NIF / ERTS
FROM ${ERLANG_ALPINE_BASE}
# Build provenance (v2.1 spec Part C.3): the git SHA is baked BOTH as
# the OCI revision LABEL and as an ENV — image labels are INVISIBLE to
# the running container, the ENV feeds boot -> persistent_term
# (janus_build) -> /stats/sched `git_sha` + the worker hello git_sha.
# A missing --build-arg stamps the literal "unknown" (never empty).
ARG JANUS_GIT_SHA=unknown
LABEL org.opencontainers.image.revision="${JANUS_GIT_SHA}"
ENV JANUS_GIT_SHA=${JANUS_GIT_SHA}
WORKDIR /opt/janus
COPY --from=build /app/_build/prod/rel/janus ./
RUN mkdir -p /var/lib/janus &&     addgroup -S janus && adduser -S janus -G janus &&     chown -R janus:janus /opt/janus /var/lib/janus
USER janus
ENV JANUS_SQLITE_PATH=/var/lib/janus/janus.db
# 8080 = data plane, 8090 = admin stats plane (dashboard polls /stats)
EXPOSE 8080 8090
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/healthz || wget -qO- http://127.0.0.1:8090/healthz || exit 1
COPY docker-entrypoint.sh /docker-entrypoint.sh
# Shared vm.args/TLS renderer sourced by the entrypoint (F5c) — the
# same file ships inside the bare release tarball via the relx
# overlay. Deploy order matters: an entrypoint bind-mounted from a
# stacks dir into an image built BEFORE this line boots the old
# inline renderer (still fine — outputs are identical).
COPY scripts/lib/janus_vm_args.sh /usr/local/lib/janus/janus_vm_args.sh
USER root
ARG APK_MIRROR=https://mirrors.aliyun.com
# Explicit modes, not umask-dependent: a checkout made with umask 027
# yields 750/640 source files, COPY preserves that, and the non-root
# janus user then cannot READ the entrypoint or the sourced vm-args
# renderer ("Permission denied" at exec -- seen on a host with umask
# 027). chmod the pair world-readable before dropping privileges.
RUN set -eux; \
    chmod 755 /docker-entrypoint.sh; \
    chmod 644 /usr/local/lib/janus/janus_vm_args.sh; \
    cp /etc/apk/repositories /tmp/apk-repos.orig; \
    for m in "${APK_MIRROR}" https://dl-cdn.alpinelinux.org; do \
      sed "s#https://dl-cdn.alpinelinux.org#${m}#g" /tmp/apk-repos.orig > /etc/apk/repositories; \
      if apk add --no-cache openssl; then exit 0; fi; \
      echo "openssl via ${m} unavailable — trying the next mirror" >&2; \
    done; \
    echo "openssl unavailable via every mirror — carrying on (optional, as before)" >&2; exit 0
USER janus
ENTRYPOINT ["/docker-entrypoint.sh"]
