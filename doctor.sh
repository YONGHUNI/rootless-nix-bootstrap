#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rootless-nix-bootstrap"
STATE_FILE="$CONFIG_DIR/state.env"

status=0
check_ok() { printf '[OK] %s\n' "$*"; }
check_warn() { printf '[WARN] %s\n' "$*"; }
check_fail() { printf '[FAIL] %s\n' "$*"; status=1; }

printf 'rootless-nix-bootstrap doctor\n\n'

if [[ -r "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    check_ok "state: $STATE_FILE"
    printf '  backend: %s\n  store:   %s\n' "$RNB_BACKEND" "$RNB_STORE_ROOT"
else
    check_fail "state file missing: $STATE_FILE"
    exit "$status"
fi

if command -v nix >/dev/null 2>&1; then
    check_ok "nix command: $(command -v nix)"
else
    check_fail "nix is not on PATH"
fi

if nix --version >/dev/null 2>&1; then
    check_ok "$(nix --version)"
else
    check_fail "nix --version failed"
fi

if nix eval --expr '1 + 1' 2>/dev/null | grep -qx '2'; then
    check_ok "Nix evaluator works"
else
    check_fail "Nix evaluator test failed"
fi

tmp_flake=$(mktemp -d)
trap 'rm -rf "$tmp_flake"' EXIT
cat > "$tmp_flake/flake.nix" <<'EOF_FLAKE'
{ outputs = { self }: { lib.smoke = "ok"; }; }
EOF_FLAKE
if nix flake metadata --no-write-lock-file "path:$tmp_flake" >/dev/null 2>&1; then
    check_ok "flake support works"
else
    check_fail "flake metadata test failed"
fi

if [[ "$RNB_BACKEND" == user-chroot ]]; then
    if command -v unshare >/dev/null 2>&1 && unshare --user --pid true >/dev/null 2>&1; then
        check_ok "unprivileged user namespaces available"
    else
        check_warn "unprivileged user namespace probe fails outside the wrapper"
    fi

    sandbox_setting=$(nix config show 2>/dev/null | awk -F ' = ' '$1 == "sandbox" { print $2; exit }')
    case "$sandbox_setting" in
        true) check_ok "Nix build sandbox enabled" ;;
        false) check_warn "Nix build sandbox disabled on this host" ;;
        *) check_warn "Could not determine Nix build sandbox setting" ;;
    esac
fi

if command -v nvidia-smi >/dev/null 2>&1; then
    check_ok "NVIDIA host driver visible"
    if [[ -e "$RNB_STORE_ROOT/var/nix/opengl-driver/lib/libcuda.so.1" ]]; then
        check_ok "libcuda.so.1 bridge configured"
    elif [[ "$RNB_BACKEND" == user-chroot ]]; then
        check_warn "libcuda.so.1 bridge is not configured"
    fi
else
    printf '[--] NVIDIA GPU not detected\n'
fi

exit "$status"
