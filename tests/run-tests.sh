#!/usr/bin/env bash
set -euo pipefail
TEST_DIR=$(dirname "$0")
REPO_ROOT=$(cd "$TEST_DIR/.." && pwd)
export PATH="$REPO_ROOT/tests/bin:$PATH"
TMPDIR=$(mktemp -d)
#trap 'rm -rf "$TMPDIR"' EXIT
TEST_TMPDIR_PREFIX="$TEST_DIR/.data"


fail() { echo "FAIL: $1"; exit 1; }

# helper to write helm status json
write_status() {
  cat > "$TEST_TMPDIR/helm_status.json" <<JSON
{
  "info": {
    "status": "$1",
    "last_deployed": "$2"
  },
  "namespace": "default",
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

echo "All tests passed"
