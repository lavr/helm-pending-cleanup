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
  -n, --namespace <value>   Kubernetes namespace to target.
  -h, --help                Show this help and exit.
EOF
}

log()   { [[ "$VERBOSE" == "true" ]] && echo "[pending-cleanup] $*" >&2; }
error() { echo "[pending-cleanup][ERROR] $*" >&2; exit 1; }

parse_duration() {                # Converts 10m/4h/2d/1w to seconds
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
USER_NS=""
while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--verbose) VERBOSE=true; shift ;;
    -n|--namespace)
        shift
        [[ $# -gt 0 ]] || error "--namespace requires value"
        USER_NS=$1
        shift
        ;;
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
HELM_NS_ARGS=()
[[ -n "$USER_NS" ]] && HELM_NS_ARGS=(-n "$USER_NS")

log "Fetching status for release '$RELEASE' ${USER_NS:+in namespace '$USER_NS'}"
release_json=$(helm status "${HELM_NS_ARGS[@]}" "$RELEASE" -o json 2>/dev/null) \
  || error "helm status failed for '$RELEASE'"

status=$(jq -r '.info.status' <<<"$release_json")
last_deploy=$(jq -r '.info.last_deployed' <<<"$release_json")
ns_from_status=$(jq -r '.namespace' <<<"$release_json")
TARGET_NS=${USER_NS:-$ns_from_status}

last_epoch=$(date -d "$last_deploy" +%s) || error "Cannot parse last_deployed"

if [[ "$AGE_SPEC" =~ ^[0-9]+$ ]]; then
  threshold_epoch=$AGE_SPEC
else
  dur_seconds=$(parse_duration "$AGE_SPEC") \
    || error "Invalid duration '$AGE_SPEC'"
  threshold_epoch=$(( $(date +%s) - dur_seconds ))
fi

log "Status      : $status"
log "Last deploy : $last_deploy ($last_epoch)"
log "Threshold   : $(date -d @"$threshold_epoch" '+%Y-%m-%d %H:%M:%S')"
log "Namespace   : $TARGET_NS"

###############################################################################
# Decision & action
###############################################################################
if [[ "$status" =~ ^pending ]]; then
  if (( last_epoch <= threshold_epoch )); then
    log "Release qualifies for cleanup: status=$status"
    secrets=$(kubectl get secrets -n "$TARGET_NS" \
              -l "owner=helm,name=$RELEASE" \
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
          log "Deleting secret: $s"
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
