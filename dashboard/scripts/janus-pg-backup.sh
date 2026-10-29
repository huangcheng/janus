#!/bin/bash
# Nightly full-logical backup of the janus DB (65MB — cheap). Keeps 14d.
# Each file is integrity-checked via pg_restore -l against the same postgres:16-alpine.
set -euo pipefail
DEST=/opt/janus/backups/pg
install -d -m 700 "$DEST"
STAMP=$(date +%Y%m%d-%H%M%S)
docker exec postgres pg_dump -U janus -Fc janus > "$DEST/janus-$STAMP.dump"
docker run --rm -i -v "$DEST/janus-$STAMP.dump:/d.dump:ro" postgres:16-alpine pg_restore -l /d.dump >/dev/null
find "$DEST" -name '*.dump' -mtime +14 -delete
echo "backup ok: janus-$STAMP.dump ($(du -h "$DEST/janus-$STAMP.dump" | cut -f1))"
