#!/bin/bash
# Reconcile firewall + aliyun SG to one source of truth: the dashboard's gateway_nodes table.
#
# Single source of truth: /api/nodes (gateway_nodes). Anything not listed is dead.
# Host: the per-node firewalld rich-rule for 25672 (workers + dashboard peer).
# Cloud: the aliyun ECS SG ingress rule for 25672 over the same set.
#
# Usage:
#   recon-firewall.sh [--dry-run] [--roster-from-dashboard]
#
# Requires: psql env from /opt/stacks/janus/.env.db (or JANUS_DB_HOST/PORT/USER/PASSWORD),
#          aliyun CLI configured (AccessKey ID/secret), host firewalld.

set -euo pipefail
DRY=0
ROSTER=dash
for a in "$@"; do
  case "$a" in --dry-run) DRY=1 ;; --roster-from-host) ROSTER=host ;; esac
done

cd /opt/stacks/janus
DBENV=$(grep -E '^JANUS_DB_(HOST|PORT|USER|PASSWORD|NAME)=' .env 2>/dev/null)
[ -z "$DBENV" ] && DBENV=$(grep -E '^JANUS_DB_' /opt/stacks/janus/.env.db 2>/dev/null || true)
eval "$DBENV"
PORT=25672

# Roster of allowed source IPs: every node marked role=worker (dashboard is master peer)
mapfile -t ALLOW < <(PGPASSWORD="$JANUS_DB_PASSWORD" psql -h "$JANUS_DB_HOST" -p "$JANUS_DB_PORT" -U "$JANUS_DB_USER" -d "${JANUS_DB_NAME:-janus}" -At -c "
  SELECT split_part(stats_host, ':', 1) FROM gateway_nodes
  WHERE enabled = TRUE AND role IN ('worker','master') AND stats_host LIKE 'http%';")
ALLOW+=("127.0.0.1/32")
echo "roster ($(printf '%s\n' "${ALLOW[@]}" | wc -l) entries):"
printf '  %s\n' "${ALLOW[@]}"

# Host firewalld: one rich-rule per allow entry
cur_fw=$(firewall-cmd --zone=trusted --list-rich-rules 2>/dev/null || true)
for ip in "${ALLOW[@]}"; do
  rule="rule family=ipv4 source address=${ip} port port=${PORT} protocol=tcp accept"
  if ! grep -F "$rule" <<<"$cur_fw" >/dev/null; then
    echo "firewalld: +add $rule"
    [ "$DRY" = 0 ] && firewall-cmd --zone=trusted --add-rich-rule="$rule"
  fi
done
# Remove stale (any rule for the same port whose source isn't in ALLOW)
while IFS= read -r r; do
  src=$(sed -nE "s/.*source address=(\S+) .*/\1/p" <<<"$r")
  [ -z "$src" ] && continue
  keep=0; for ip in "${ALLOW[@]}"; do [ "$ip" = "$src" ] && keep=1; done
  if [ $keep = 0 ]; then
    echo "firewalld: -rm $r"
    [ "$DRY" = 0 ] && firewall-cmd --zone=trusted --remove-rich-rule="$r"
  fi
done <<<"$cur_fw"
[ "$DRY" = 0 ] && firewall-cmd --runtime-to-permanent

# aliyun SG: revise 25672/tcp ingress to exactly ALLOW
if command -v aliyun >/dev/null; then
  SG=${JANUS_SG_ID:-sg-n4aiqokdvu38761lrjb8}
  REGION=${JANUS_REGION:-cn-wuhan-lr}
  set +e
  LIVE=$(aliyun ecs DescribeSecurityGroupAttribute --RegionId "$REGION" --SecurityGroupId "$SG" --Direction ingress 2>/dev/null \
    | python3 -c 'import sys,json; print("\n".join(p["SourceCidrIp"] for p in json.load(sys.stdin)["Permissions"]["Permission"] if "25672" in p.get("PortRange","")))')
  set -e
  echo "live SG (25672/tcp ingress):"
  printf '  %s\n' $LIVE
  for ip in "${ALLOW[@]}"; do
    grep -Fxq "$ip" <<<"$LIVE" || { echo "SG: +add $ip"; [ "$DRY" = 0 ] && aliyun ecs AuthorizeSecurityGroupIngress --RegionId "$REGION" --SecurityGroupId "$SG" --IpProtocol tcp --PortRange 25672/25672 --SourceCidrIp "$ip"; }
  done
  for ip in $LIVE; do
    keep=0; for a in "${ALLOW[@]}"; do [ "$ip" = "$a" ] && keep=1; done
    if [ $keep = 0 ]; then
      echo "SG: -rm $ip"
      [ "$DRY" = 0 ] && aliyun ecs RevokeSecurityGroupIngress --RegionId "$REGION" --SecurityGroupId "$SG" --IpProtocol tcp --PortRange 25672/25672 --SourceCidrIp "$ip"
    fi
  done
fi
