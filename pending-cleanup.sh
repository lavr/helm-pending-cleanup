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
#-------------------------------------------------------------------------------
# to_epoch(): Convert ISO-8601 from Helm to epoch seconds on any platform
#-------------------------------------------------------------------------------
to_epoch() {
  local raw="$1"

  # 1) Normalization ------------------------------------------------------------
  #    * 'Z'  → '+0000'
  #    * drop nanoseconds
  #    * '+00:00' → '+0000'
  local norm="$raw"
  norm="${norm/Z/+0000}"
  norm="$(echo "$norm" | sed -E 's/\.[0-9]+([+-].*)/\1/')"          # strip .nsec
  norm="$(echo "$norm" | sed -E 's/([+-][0-9]{2}):?([0-9]{2})/\1\2/')" # tz colon

  # 2) Try GNU date --------------------------------------------------------
  if date --version >/dev/null 2>&1; then
    date -u -d "$norm" +%s && return
  fi

  # 3) Try BusyBox date (-D) ----------------------------------------
  if date -u -D '%Y-%m-%dT%H:%M:%S' -d "$norm" +%s 2>/dev/null; then
    return
  fi

  # 4) Try BSD/macOS date --------------------------------------------------
  if date -j -u -f '%Y-%m-%dT%H:%M:%S' "$norm" '+%s' 2>/dev/null; then
    return
  fi

  # 5) All fails ------------------------------------------------------
  echo "[pending-cleanup][ERROR] Cannot parse date '$raw'" >&2
  return 1
}


#-------------------------------------------------------------------------------
# Convert epoch → human-readable UTC (works on GNU, BSD, BusyBox, Bash ≥ 4.2).
#-------------------------------------------------------------------------------
human_date() {
  local e="$1"

  # 1) GNU coreutils: date -d "@<epoch>"
  if date --version >/dev/null 2>&1; then
    date -u -d "@$e" '+%Y-%m-%d %H:%M:%S'
    return
  fi

  # 2) BSD/macOS: date -r <epoch>
  if date -u -r "$e" '+%Y-%m-%d %H:%M:%S' >/dev/null 2>&1; then
    date -u -r "$e" '+%Y-%m-%d %H:%M:%S'
    return
  fi

  # 3) BusyBox (if supports -d "@<epoch>")
  if date -u -d "@$e" '+%Y-%m-%d %H:%M:%S' >/dev/null 2>&1; then
    date -u -d "@$e" '+%Y-%m-%d %H:%M:%S'
    return
  fi

  # 4) Fallback: Bash builtin printf '%T' (Bash ≥ 4.2, TZ=UTC)
  TZ=UTC printf '%(%Y-%m-%d %H:%M:%S)T\n' "$e"
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
