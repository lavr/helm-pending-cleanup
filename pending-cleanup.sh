#!/usr/bin/env bash
# pending-cleanup: Helm plugin to purge or list stale pending releases
# All log messages and comments are in technical English.

set -euo pipefail

###############################################################################
# Functions
###############################################################################
usage() {
cat <<EOF
Usage:
  helm pending-cleanup [flags] <release> <age> <action>

Arguments:
  release   Helm release name.
  age       Threshold age (epoch seconds) OR duration string (e.g. 30m, 2h, 7d).
  action    What to do when matched: print | delete

Flags:
  -v, --verbose             Verbose log output.
  -h, --help                Show this help and exit.
EOF
}

log()   { [[ "$VERBOSE" == "true" ]] && echo "[pending-cleanup] $*" >&2 || true; }
error() { echo "[pending-cleanup][ERROR] $*" >&2; exit 1; }

#-------------------------------------------------------------------------------
# Convert ISO-8601 date from Helm to epoch seconds (GNU + BSD/macOS).
# Handles nanoseconds and "Z" or "+HH:MM" time-zones.
#-------------------------------------------------------------------------------
to_epoch() {
  local raw="$1"

  # GNU coreutils present → easiest path
  if date --version >/dev/null 2>&1; then
    date -u -d "$raw" +%s
    return
  fi

  # ---- BSD path --------------------------------------------------------------
  local norm="$raw"

  # 1) Convert trailing "Z" to "+0000"
  norm="${norm/Z/+0000}"

  # 2) Remove fractional seconds (".123456789")
  norm="$(echo "$norm" | sed -E 's/\.[0-9]+([+-].*)/\1/')"

  # 3) Remove colon in time-zone offset ("+00:00" → "+0000")
  norm="$(echo "$norm" | sed -E 's/([+-][0-9]{2}):?([0-9]{2})/\1\2/')"

  # 4) Parse: 2025-01-31T14:31:34+0000
  date -j -u -f '%Y-%m-%dT%H:%M:%S%z' "$norm" '+%s' 2>/dev/null \
    || { echo "[pending-cleanup][ERROR] Cannot parse date '$raw'" >&2; return 1; }
}

# Print epoch in human-readable UTC form.
human_date() {
  local e="$1"
  if date --version >/dev/null 2>&1; then
    date -u -d "@$e" '+%Y-%m-%d %H:%M:%S'
  else
    date -u -r "$e" '+%Y-%m-%d %H:%M:%S'
  fi
}

# Converts 10m/4h/2d/1w to seconds
parse_duration() {
  [[ "$1" =~ ^([0-9]+)([smhdw])$ ]] || return 1
  local n=${BASH_REMATCH[1]} u=${BASH_REMATCH[2]}
  case $u in
    s) printf '%s\n' "$((n))" ;;
    m) printf '%s\n' "$((n*60))" ;;
    h) printf '%s\n' "$((n*3600))" ;;
    d) printf '%s\n' "$((n*86400))" ;;
    w) printf '%s\n' "$((n*604800))" ;;
    *) return 1 ;;
  esac
}

###############################################################################
# CLI parsing
###############################################################################
VERBOSE=false
while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--verbose) VERBOSE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) error "Unknown flag: $1" ;;
    *)  break ;;
  esac
done

[[ $# -eq 3 ]] || { usage; exit 1; }
RELEASE=$1 AGE_SPEC=$2 ACTION=$3
[[ "$ACTION" == "print" || "$ACTION" == "delete" ]] \
  || error "Action must be 'print' or 'delete'"

for cmd in helm kubectl jq; do command -v "$cmd" >/dev/null || error "$cmd not found"; done

###############################################################################
# Release inspection
###############################################################################

log "Fetching status for release '$RELEASE'"
release_json=$(helm status "$RELEASE" -o json 2>/dev/null) \
  || error "helm status failed for '$RELEASE'"

status=$(jq -r '.info.status'       <<<"$release_json")
last_deploy=$(jq -r '.info.last_deployed' <<<"$release_json")
ns_from_status=$(jq -r '.namespace'  <<<"$release_json")
revision=$(jq -r '.version'  <<<"$release_json")
TARGET_NS=$ns_from_status

last_epoch=$(to_epoch "$last_deploy") || error "Cannot parse last_deployed"

if [[ "$AGE_SPEC" =~ ^[0-9]+$ ]]; then
  threshold_epoch=$AGE_SPEC
else
  dur_seconds=$(parse_duration "$AGE_SPEC") || error "Invalid duration '$AGE_SPEC'"
  threshold_epoch=$(( $(date +%s) - dur_seconds ))
fi

log "Status      : $status"
log "Last deploy : $last_deploy ($last_epoch)"
log "Threshold   : $(human_date "$threshold_epoch")"
log "Namespace   : $TARGET_NS"

###############################################################################
# Decision & action
###############################################################################
if [[ "$status" =~ ^pending ]]; then
  if (( last_epoch <= threshold_epoch )); then
    log "Release qualifies for cleanup"
    secrets=$(kubectl get secrets -n "$TARGET_NS" \
              -l "owner=helm,name=$RELEASE,version=$revision" \
              -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    if [[ -z "$secrets" ]]; then
      log "No secrets found; nothing to do"
      exit 0
    fi
    if [[ "$ACTION" == "print" ]]; then
      printf '%s\n' $secrets
    else
      for s in $secrets; do
        if [[ "$VERBOSE" == "true" ]]; then
          kubectl delete secret "$s" -n "$TARGET_NS"
        else
          kubectl delete secret "$s" -n "$TARGET_NS" --ignore-not-found >/dev/null 2>&1
        fi
      done
    fi
  else
    log "Release age below threshold; skipped"
  fi
else
  log "Release status '$status' is not pending; skipped"
fi
