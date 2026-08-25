#!/usr/bin/env bash

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
errors=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors + 1)); }

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

mkdir -p "$test_root/bin"

cat >"$test_root/bin/curl" <<'EOF'
#!/bin/sh
case " $* " in
*" %{http_code} "*) printf '204' ;;
*) printf '%s\n' '{}' ;;
esac
EOF
chmod +x "$test_root/bin/curl"

cat >"$test_root/bin/fzf" <<'EOF'
#!/bin/sh
/usr/bin/head -n 1
EOF
chmod +x "$test_root/bin/fzf"

cat >"$test_root/yq" <<'EOF'
#!/bin/sh
case " $* " in
*" -n "*) printf '%s\n' '{"name":"node"}' ;;
*)
    input=$(/bin/cat)
    [ -n "$input" ] || exit 1
    printf 'proxy\tSelector\tnode\n'
    ;;
esac
EOF
chmod +x "$test_root/yq"

cat >"$test_root/probe.sh" <<'EOF'
CLASHCTL_HOME=$1
export CLASHCTL_HOME
. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"

service_is_active() { return 0; }
_detect_ext_addr() {
    awk 'BEGIN { exit 0 }' </dev/null || return
    EXT_PORT=9090
}
_get_secret() { return 0; }

BIN_YQ=$2
PATH=$3
export PATH
shift 3

if [ "${1:-}" = --force-fzf ]; then
    _node_has_fzf() { return 0; }
    shift
fi

if [ -n "${ZSH_VERSION:-}" ]; then
    caller_array=(first second)
fi

clashctl "$@"
command_status=$?

if [ -n "${ZSH_VERSION:-}" ] && [ "${caller_array[1]}" != first ]; then
    printf 'clashctl node leaked ksharrays into the caller\n' >&2
    exit 95
fi

exit "$command_status"
EOF

run_case() {
    local shell=$1 name=$2 expected=$3 output status baseline_path
    shift 3
    output="$test_root/${shell}-${name}.out"
    baseline_path="$test_root/bin:/usr/bin:/bin"

    "$shell" "$test_root/probe.sh" "$REPO_ROOT" "$test_root/yq" "$baseline_path" \
        "$@" \
        >"$output" 2>&1
    status=$?

    if [ "$status" -eq 0 ] &&
        ! grep -Eq 'command not found|bad substitution|unrecognized modifier|read-only variable' "$output" &&
        grep -q "$expected" "$output"; then
        pass "$shell $name"
    else
        fail "$shell $name (status $status)"
        sed -n '1,20p' "$output"
    fi
}

for shell in bash zsh; do
    command -v "$shell" >/dev/null 2>&1 || continue
    run_case "$shell" 'lists groups' 'Selector' node ls
    run_case "$shell" 'switches a node' '已切换 \[proxy\] → node' node use proxy node
    run_case "$shell" 'selects through fzf' '已切换 \[proxy\]' --force-fzf node
done

if [ "$errors" -eq 0 ]; then
    echo 'PASS: clashctl node shell compatibility'
    exit 0
fi

echo "FAIL: clashctl node shell compatibility ($errors error(s))"
exit 1
