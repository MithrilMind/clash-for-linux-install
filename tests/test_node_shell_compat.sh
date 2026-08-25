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

fixture_home="$test_root/home"
mkdir -p "$test_root/bin" "$fixture_home/resources" \
    "$fixture_home/scripts/cmd" "$fixture_home/scripts/lib"
cp "$REPO_ROOT"/scripts/cmd/*.sh "$fixture_home/scripts/cmd/"
cp "$REPO_ROOT"/scripts/cmd/*.zsh "$fixture_home/scripts/cmd/"

cat >"$fixture_home/.env" <<'EOF'
CLASHCTL_KERNEL=mihomo
EOF

cat >"$fixture_home/scripts/lib/common.sh" <<'EOF'
BIN_YQ=$CLASHCTL_TEST_YQ
CLASH_CONFIG_RUNTIME=$CLASHCTL_HOME/resources/runtime.yaml

service_is_active() { return 0; }
_detect_ext_addr() {
    awk 'BEGIN { exit 0 }' </dev/null || return
    EXT_PORT=9090
}
_get_secret() { return 0; }
_dispwidth() { printf '%s\n' "${#1}"; }
_pad() { printf '%-*s' "$2" "$1"; }
_okcat() { printf '%s\n' "$*"; }
_failcat() { printf '%s\n' "$*" >&2; return 1; }
_errorcat() { printf '%s\n' "$*" >&2; return 1; }
EOF

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
CLASHCTL_TEST_YQ=$2
PATH=$3
export CLASHCTL_HOME CLASHCTL_TEST_YQ PATH
shift 3
. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"

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

    "$shell" "$test_root/probe.sh" "$fixture_home" "$test_root/yq" "$baseline_path" \
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

run_case bash 'lists groups' 'Selector' node ls
run_case bash 'switches a node' '已切换 \[proxy\] → node' node use proxy node
run_case bash 'selects through fzf' '已切换 \[proxy\]' --force-fzf node

if command -v zsh >/dev/null 2>&1; then
    run_case zsh 'lists groups through Bash adapter' 'Selector' node ls
    run_case zsh 'switches a node through Bash adapter' '已切换 \[proxy\] → node' node use proxy node
fi

if [ "$errors" -eq 0 ]; then
    echo 'PASS: clashctl node shell compatibility'
    exit 0
fi

echo "FAIL: clashctl node shell compatibility ($errors error(s))"
exit 1
