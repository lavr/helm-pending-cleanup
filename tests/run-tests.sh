#!/usr/bin/env bash
set -euo pipefail
TEST_DIR=$(dirname "$0")
REPO_ROOT=$(cd "$TEST_DIR/.." && pwd)
export PATH="$REPO_ROOT/tests/bin:$PATH"
TMP_ROOT="$TEST_DIR/.tmp"
mkdir -p "$TMP_ROOT"
TMPDIR=$(mktemp -d "$TMP_ROOT/run.XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT
TEST_TMPDIR_PREFIX="$TEST_DIR/.data"
rm -rf "$TEST_TMPDIR_PREFIX"
mkdir -p "$TEST_TMPDIR_PREFIX"


fail() { echo "FAIL: $1"; exit 1; }

# helper to write helm status json
write_status() {
  local ns=${3:-default}
  cat > "$TEST_TMPDIR/helm_status.json" <<JSON
{
  "info": {
    "status": "$1",
    "last_deployed": "$2"
  },
  "namespace": "$ns",
  "version": 1
}
JSON
}

# helper to write secrets list
write_secrets() {
  printf '%s\n' "$@" > "$TEST_TMPDIR/kubectl_get_secrets.txt"
}

# Test printing secrets for pending release
export TEST_TMPDIR=$TEST_TMPDIR_PREFIX/01
mkdir -p "$TEST_TMPDIR"
write_status "pending-install" "2023-01-01T00:00:00Z"
write_secrets secret1 secret2
output=$("$REPO_ROOT/pending-cleanup.sh" test-release 1h print)
[[ "$output" == $'secret1\nsecret2' ]] || fail "unexpected output for print"
[[ ! -f "$TEST_TMPDIR/kubectl_delete.log" ]] || fail "delete log present for print"

# Test deletion of secrets
export TEST_TMPDIR=$TEST_TMPDIR_PREFIX/02
mkdir -p "$TEST_TMPDIR"
write_status "pending-upgrade" "2023-01-01T00:00:00Z"
write_secrets s1 s2
"$REPO_ROOT/pending-cleanup.sh" test-release 1h delete >/dev/null
[[ -f "$TEST_TMPDIR/kubectl_delete.log" ]] || fail "delete log missing"
count=$(wc -l < "$TEST_TMPDIR/kubectl_delete.log")
[[ "$count" -eq 2 ]] || fail "expected 2 delete calls, got $count"

# Test non-pending release does nothing
export TEST_TMPDIR=$TEST_TMPDIR_PREFIX/03
mkdir -p "$TEST_TMPDIR"
write_status "deployed" "2023-01-01T00:00:00Z"
write_secrets foo
"$REPO_ROOT/pending-cleanup.sh" test-release 1h print >/dev/null
[[ ! -f "$TEST_TMPDIR/kubectl_delete.log" ]] || fail "delete called for deployed"

# Test handling of helm warnings and namespace flag
export TEST_TMPDIR=$TEST_TMPDIR_PREFIX/04
mkdir -p "$TEST_TMPDIR"
cat > "$TEST_TMPDIR/helm_status_raw" <<JSON
WARNING: noisy plugin output
{
  "info": {
    "status": "pending-install",
    "last_deployed": "2023-01-01T00:00:00Z"
  },
  "namespace": "ns-warning",
  "version": 3
}
JSON
write_secrets warn-secret
output=$(HELM_NAMESPACE=ns-warning EXPECTED_HELM_NAMESPACE=ns-warning \
  "$REPO_ROOT/pending-cleanup.sh" test-release 1h print)
[[ "$output" == "warn-secret" ]] || fail "unexpected output for warning handling"

# Test empty secrets list (pending release but no matching secrets)
export TEST_TMPDIR=$TEST_TMPDIR_PREFIX/05
mkdir -p "$TEST_TMPDIR"
write_status "pending-install" "2023-01-01T00:00:00Z"
printf '' > "$TEST_TMPDIR/kubectl_get_secrets.txt"
output=$("$REPO_ROOT/pending-cleanup.sh" test-release 1h print)
[[ -z "$output" ]] || fail "expected empty output for no secrets, got: $output"
[[ ! -f "$TEST_TMPDIR/kubectl_delete.log" ]] || fail "delete log present for empty secrets"

echo "All tests passed"
