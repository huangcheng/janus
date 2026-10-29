#!/bin/sh
# Janus release entrypoint: renders fleet-mode vm.args + TLS optfile
# before exec'ing the release (spec 2026-10-08 Part A). Fleet knob off
# => today's boot exactly (cookie written to ~/.erlang.cookie).
# Master/worker pool: inet_tls when role=worker OR JANUS_FLEET_ENABLED
# OR JANUS_FLEET_PEERS is set (master listens for worker hello without
# starting signal-fleet children).
#
# The vm.args/TLS rendering lives in scripts/lib/janus_vm_args.sh
# (extracted per spec 2026-10-15-bare-metal-deploy F5c) and is shared
# with the bare release wrapper that ships inside the release tarball
# — ONE renderer, no drift between the container and bare paths.
# Search order: $JANUS_VM_ARGS_LIB, the image-baked copy
# (/usr/local/lib/janus/janus_vm_args.sh), then a source checkout next
# to this script. Knobs, validation and outputs are UNCHANGED:
#   JANUS_NET_TICKTIME  seconds 10..120  -> "-kernel net_ticktime N"
#   JANUS_ZDBBL         KB 128..65536    -> "+zdbbl N"
# Both are BOOT-TIME ONLY (no code reads them; the vm.args lines are
# inert to old beams). Rendering is IDEMPOTENT: the vm.args block below
# regenerates the file from scratch every boot, so any pre-existing
# net_ticktime/+zdbbl lines are REPLACED, never appended (no duplicate
# flags across container restarts). Unset or invalid values are DROPPED
# with a warning on stderr and the OTP defaults apply — a malformed env
# value must never produce an unbootable node. CLUSTER SYMMETRY:
# net_ticktime changes must land on ALL nodes in ONE deploy window
# (asymmetric ticktime flaps dist connections — runbook G.5).
set -eu
REL_DIR="/opt/janus"

# Locate the shared renderer (see header). The image bakes it at
# /usr/local/lib/janus/janus_vm_args.sh; a repo checkout carries it at
# scripts/lib/janus_vm_args.sh next to this script.
if [ -z "${JANUS_VM_ARGS_LIB:-}" ]; then
  # busybox dirname has no "--" — plain dirname is busybox-safe (a $0
  # starting with "-" cannot happen for this entrypoint).
  _entry_dir="$(dirname "$0")"
  for _cand in /usr/local/lib/janus/janus_vm_args.sh \
               "$_entry_dir/scripts/lib/janus_vm_args.sh" \
               "./scripts/lib/janus_vm_args.sh"; do
    if [ -f "$_cand" ]; then
      JANUS_VM_ARGS_LIB="$_cand"
      break
    fi
  done
fi
if [ -z "${JANUS_VM_ARGS_LIB:-}" ] || [ ! -f "$JANUS_VM_ARGS_LIB" ]; then
  echo "janus: vm.args renderer lib not found (expected /usr/local/lib/janus/janus_vm_args.sh in the image, or scripts/lib/janus_vm_args.sh in a checkout)" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$JANUS_VM_ARGS_LIB"

janus_vm_render "$REL_DIR"
exec "$REL_DIR/bin/janus" foreground
