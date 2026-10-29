#!/usr/bin/env bash
# Fetch GeoLite2-City.mmdb (MaxMind CC BY-SA 4.0) to DEST.
#
#   JANUS_MAXMIND_ACCOUNT_ID=… JANUS_MAXMIND_LICENSE_KEY=… \
#     bash scripts/fetch_geolite2_mmdb.sh /path/to/GeoLite2-City.mmdb
#
# Auth: HTTP Basic (account_id:license_key) against the current MaxMind
# download permalink. A failed refresh leaves any existing DEST untouched
# (stale geo is acceptable; only missing/corrupt files are replaced).
#
# Integrity: the MaxMind DB metadata marker and a 1 MB size floor are
# always checked. JANUS_GEOLITE2_MMDB_SHA256 (optional) pins the .mmdb
# hash and fails closed on mismatch; with it unset the artefact is
# installed but reported as UNVERIFIED.
#
# Never commit license keys. See repo NOTICE + skills/fleet-node-ops.
set -euo pipefail

DEST="${1:-}"
if [ -z "$DEST" ]; then
  echo "usage: $0 /absolute/or/relative/path/GeoLite2-City.mmdb" >&2
  exit 2
fi

ACCOUNT_ID="${JANUS_MAXMIND_ACCOUNT_ID:-${MAXMIND_ACCOUNT_ID:-}}"
LICENSE_KEY="${JANUS_MAXMIND_LICENSE_KEY:-${MAXMIND_LICENSE_KEY:-}}"
if [ -z "$ACCOUNT_ID" ] || [ -z "$LICENSE_KEY" ]; then
  echo "FAIL: JANUS_MAXMIND_ACCOUNT_ID and JANUS_MAXMIND_LICENSE_KEY required" >&2
  exit 1
fi

URL="${JANUS_MAXMIND_DOWNLOAD_URL:-https://download.maxmind.com/geoip/databases/GeoLite2-City/download?suffix=tar.gz}"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/janus-geolite2.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

TGZ="$WORKDIR/GeoLite2-City.tar.gz"
NEW="$DEST.new.$$"
NETRC="$WORKDIR/netrc"
mkdir -p "$(dirname "$DEST")"

# Auth via netrc so credentials never appear in `ps` argv (unlike -u).
# Never echo credentials.
umask 077
printf 'machine download.maxmind.com\nlogin %s\npassword %s\n' \
  "$ACCOUNT_ID" "$LICENSE_KEY" > "$NETRC"
# Follow redirects (R2 presigned URL).
# Prefer --fail-with-body (curl ≥7.76); fall back to --fail.
CURL_FAIL=(--fail-with-body)
curl -sS -L --fail-with-body -o /dev/null -w '' 'https://example.com' >/dev/null 2>&1 || CURL_FAIL=(--fail)
HTTP_CODE="$(
  curl -sS -L "${CURL_FAIL[@]}" \
    --netrc-file "$NETRC" \
    -o "$TGZ" \
    -w '%{http_code}' \
    "$URL" || true
)"
rm -f "$NETRC"
if [ ! -s "$TGZ" ] || [ "$HTTP_CODE" != "200" ]; then
  echo "FAIL: MaxMind download http=$HTTP_CODE (left existing mmdb untouched if any)" >&2
  exit 1
fi

# Extract the .mmdb from the tarball (path varies by release date).
# Refuse path-traversal and option-like member names before extracting.
# `--` precedes the member so tar can never read it as an option; the
# archive is bound with --file= because GNU tar's -f consumes the next
# argv element (tested: `tar -tzf -- archive` treats `--` as the archive).
EXTRACTED="$(tar --list --gzip --file="$TGZ" | grep -E 'GeoLite2-City\.mmdb$' | head -1 || true)"
if [ -z "$EXTRACTED" ]; then
  echo "FAIL: tar.gz has no GeoLite2-City.mmdb" >&2
  exit 1
fi
case "$EXTRACTED" in
  -*|/*|*../*|*/../*|*/..|..)
    echo "FAIL: tar member has unsafe path or option-like name" >&2
    exit 1
    ;;
esac
tar --extract --gzip --file="$TGZ" --directory="$WORKDIR" -- "$EXTRACTED"
SRC="$WORKDIR/$EXTRACTED"
if [ ! -s "$SRC" ]; then
  echo "FAIL: extracted mmdb empty" >&2
  exit 1
fi

BYTES="$(wc -c < "$SRC" | tr -d ' ')"
if [ "$BYTES" -lt 1000000 ]; then
  echo "FAIL: mmdb too small (${BYTES} bytes) — refusing to install" >&2
  exit 1
fi

# MaxMind DB magic: a valid .mmdb carries the metadata marker
# (0xab 0xcd 0xef "MaxMind.com") inside the last 128 KiB — the format has
# no header at offset 0. Fail closed: a >1 MB HTML error page or a
# truncated-but-large archive must never be installed.
# (hex dump captured first: `grep -q` in a pipefail pipeline can report a
# SIGPIPE from the upstream writer even when the marker was found)
SRC_HEX="$(tail -c 131072 "$SRC" | od -An -v -tx1 | tr -d ' \n')"
case "$SRC_HEX" in
  *abcdef4d61784d696e642e636f6d*) ;;
  *)
    echo "FAIL: extracted file is not a MaxMind DB (metadata marker absent from the last 128 KiB) — refusing to install" >&2
    exit 1
    ;;
esac
unset SRC_HEX

# Integrity: verification is opt-in because no expected hash is pinned in
# this repo. JANUS_GEOLITE2_MMDB_SHA256 makes it fail closed; otherwise
# the artefact is installed but explicitly reported as UNVERIFIED.
EXPECTED_SHA="$(printf '%s' "${JANUS_GEOLITE2_MMDB_SHA256:-}" | tr 'A-F' 'a-f')"
ACTUAL_SHA="$(sha256sum "$SRC" | awk '{print $1}')"
if [ -n "$EXPECTED_SHA" ] && [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  echo "FAIL: mmdb sha256 $ACTUAL_SHA != JANUS_GEOLITE2_MMDB_SHA256 $EXPECTED_SHA — refusing to install" >&2
  exit 1
fi
if [ -z "$EXPECTED_SHA" ]; then
  echo "WARN: mmdb sha256 $ACTUAL_SHA is UNVERIFIED — set JANUS_GEOLITE2_MMDB_SHA256 to verify the artefact (magic + 1 MB floor only)" >&2
fi

cp -f "$SRC" "$NEW"
chmod 644 "$NEW"
mv -f "$NEW" "$DEST"
echo "ok: wrote $DEST (${BYTES} bytes, sha256 $ACTUAL_SHA)"
if [ -z "$EXPECTED_SHA" ]; then
  echo "      note: sha256 UNVERIFIED — no JANUS_GEOLITE2_MMDB_SHA256 configured (pin the hash to verify)"
fi
