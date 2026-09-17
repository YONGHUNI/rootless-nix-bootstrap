#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

status=0
output=''

run_capture() {
    set +e
    output=$("$@" 2>&1)
    status=$?
    set -e
}

assert_status() {
    local expected=$1
    [[ "$status" -eq "$expected" ]] || {
        printf 'expected status %s, got %s\n%s\n' "$expected" "$status" "$output" >&2
        exit 1
    }
}

assert_contains() {
    local needle=$1
    [[ "$output" == *"$needle"* ]] || {
        printf 'expected output to contain: %s\nactual:\n%s\n' "$needle" "$output" >&2
        exit 1
    }
}

make_state() {
    local config_home=$1 backend=$2 store_root=$3 backend_bin=$4 bin_dir=$5
    mkdir -p "$config_home/rootless-nix-bootstrap"
    cat > "$config_home/rootless-nix-bootstrap/state.env" <<EOF_STATE
RNB_BACKEND=$backend
RNB_STORE_ROOT=$store_root
RNB_BACKEND_BIN=$backend_bin
RNB_BIN_DIR=$bin_dir
RNB_MANAGED=1
EOF_STATE
}

# bootstrap CLI surface
run_capture "$repo_root/bootstrap.sh" --help
assert_status 0
assert_contains 'Usage: ./bootstrap.sh [options]'
assert_contains '--backend auto|user-chroot|portable'

run_capture "$repo_root/bootstrap.sh" --backend
assert_status 1
assert_contains '--backend requires an argument'

run_capture "$repo_root/bootstrap.sh" --store-root
assert_status 1
assert_contains '--store-root requires an argument'

run_capture "$repo_root/bootstrap.sh" --bin-dir
assert_status 1
assert_contains '--bin-dir requires an argument'

run_capture "$repo_root/bootstrap.sh" --definitely-invalid
assert_status 1
assert_contains 'Unknown option'

# Auto and explicit user-chroot must fail cleanly when user namespaces are blocked.
blocked_home="$tmp_root/blocked-home"
blocked_mock="$tmp_root/blocked-mock"
mkdir -p "$blocked_home" "$blocked_mock"
printf '#!/usr/bin/env bash\nexit 1\n' > "$blocked_mock/unshare"
printf '#!/usr/bin/env bash\nexit 127\n' > "$blocked_mock/nix"
chmod +x "$blocked_mock/unshare" "$blocked_mock/nix"

run_capture env HOME="$blocked_home" PATH="$blocked_mock:$PATH" \
    "$repo_root/bootstrap.sh" --store-root "$blocked_home/store" --bin-dir "$blocked_home/bin"
assert_status 2
assert_contains 'Unprivileged user namespaces are unavailable or blocked'

run_capture env HOME="$blocked_home" PATH="$blocked_mock:$PATH" \
    "$repo_root/bootstrap.sh" --backend user-chroot --store-root "$blocked_home/store" --bin-dir "$blocked_home/bin"
assert_status 1
assert_contains 'user-chroot requested'

# A pre-existing working host Nix must be left untouched.
host_home="$tmp_root/host-home"
host_mock="$tmp_root/host-mock"
mkdir -p "$host_home" "$host_mock"
cat > "$host_mock/nix" <<'EOF_NIX'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
    echo 'nix (Nix) 9.9-test'
    exit 0
fi
exit 0
EOF_NIX
chmod +x "$host_mock/nix"
run_capture env HOME="$host_home" PATH="$host_mock:$PATH" \
    "$repo_root/bootstrap.sh" --bin-dir "$host_home/bin"
assert_status 0
assert_contains 'A working host Nix installation already exists'
[[ ! -e "$host_home/bin/nix" ]]

# nix wrapper: missing state
wrapper_home="$tmp_root/wrapper-home"
wrapper_config="$tmp_root/wrapper-config"
mkdir -p "$wrapper_home" "$wrapper_config"
run_capture env HOME="$wrapper_home" XDG_CONFIG_HOME="$wrapper_config" "$repo_root/bin/nix" --version
assert_status 127
assert_contains 'state file not found'

# nix wrapper: user-chroot backend forwards arbitrary Nix arguments.
user_backend="$tmp_root/fake-user-chroot"
cat > "$user_backend" <<'EOF_BACKEND'
#!/usr/bin/env bash
shift
exec "$@"
EOF_BACKEND
chmod +x "$user_backend"
mkdir -p "$wrapper_home/.nix-profile/bin"
cat > "$wrapper_home/.nix-profile/bin/nix" <<'EOF_REAL_NIX'
#!/usr/bin/env bash
printf 'fake-nix:%s\n' "$*"
EOF_REAL_NIX
chmod +x "$wrapper_home/.nix-profile/bin/nix"
make_state "$wrapper_config" user-chroot "$wrapper_home/.nix" "$user_backend" "$wrapper_home/bin"
run_capture env HOME="$wrapper_home" XDG_CONFIG_HOME="$wrapper_config" \
    "$repo_root/bin/nix" develop -c python analysis.py
assert_status 0
assert_contains 'fake-nix:develop -c python analysis.py'

# nix wrapper: portable backend forwards commands and exports NP_LOCATION.
portable_backend="$tmp_root/fake-portable"
cat > "$portable_backend" <<'EOF_PORTABLE'
#!/usr/bin/env bash
printf 'location=%s args=%s\n' "${NP_LOCATION:-}" "$*"
EOF_PORTABLE
chmod +x "$portable_backend"
make_state "$wrapper_config" portable "$wrapper_home/portable-root" "$portable_backend" "$wrapper_home/bin"
run_capture env HOME="$wrapper_home" XDG_CONFIG_HOME="$wrapper_config" "$repo_root/bin/nix" build .#default
assert_status 0
assert_contains "location=$wrapper_home/portable-root args=nix build .#default"

# nix wrapper: unknown backend is rejected.
make_state "$wrapper_config" broken "$wrapper_home/store" "$user_backend" "$wrapper_home/bin"
run_capture env HOME="$wrapper_home" XDG_CONFIG_HOME="$wrapper_config" "$repo_root/bin/nix" --version
assert_status 2
assert_contains 'unknown backend'

# doctor: missing state and a fully healthy mocked user-chroot installation.
doctor_home="$tmp_root/doctor-home"
doctor_config="$tmp_root/doctor-config"
doctor_mock="$tmp_root/doctor-mock"
mkdir -p "$doctor_home" "$doctor_config" "$doctor_mock"
run_capture env HOME="$doctor_home" XDG_CONFIG_HOME="$doctor_config" "$repo_root/doctor.sh"
assert_status 1
assert_contains 'state file missing'

cat > "$doctor_mock/nix" <<'EOF_DOCTOR_NIX'
#!/usr/bin/env bash
case "${1:-}" in
    --version) echo 'nix (Nix) 9.9-test' ;;
    eval) echo 2 ;;
    flake) exit 0 ;;
    config)
        cat <<'EOF_CONFIG'
sandbox = true
sandbox-fallback = false
EOF_CONFIG
        ;;
    *) exit 0 ;;
esac
EOF_DOCTOR_NIX
cat > "$doctor_mock/unshare" <<'EOF_UNSHARE'
#!/usr/bin/env bash
exit 0
EOF_UNSHARE
chmod +x "$doctor_mock/nix" "$doctor_mock/unshare"
make_state "$doctor_config" user-chroot "$doctor_home/.nix" "$user_backend" "$doctor_home/bin"
run_capture env HOME="$doctor_home" XDG_CONFIG_HOME="$doctor_config" PATH="$doctor_mock:/usr/bin:/bin" \
    "$repo_root/doctor.sh"
assert_status 0
assert_contains 'Nix evaluator works'
assert_contains 'flake support works'
assert_contains 'unprivileged user namespaces available'
assert_contains 'Nix build sandbox enabled'
assert_contains 'sandbox fallback disabled'

echo 'Command surface tests passed.'
