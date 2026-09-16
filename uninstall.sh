#!/usr/bin/env bash
set -Eeuo pipefail

purge_store=0
[[ "${1:-}" == "--purge-store" ]] && purge_store=1

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/rootless-nix-bootstrap"
state_file="$config_dir/state.env"
bin_dir="${RNB_BIN_DIR:-$HOME/.local/bin}"
share_dir="${XDG_DATA_HOME:-$HOME/.local/share}/rootless-nix-bootstrap"

if [[ -r "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file"
    bin_dir="${RNB_BIN_DIR:-$bin_dir}"
else
    echo "No managed rootless-nix-bootstrap state found."
    exit 0
fi

for f in "$bin_dir/nix" "$bin_dir/rootless-nix-doctor"; do
    if [[ -f "$f" ]] && grep -q 'rootless-nix-bootstrap' "$f" 2>/dev/null; then
        rm -f "$f"
    fi
done

if [[ -f "$HOME/.bashrc" ]]; then
    tmp=$(mktemp)
    awk '
        /^# >>> rootless-nix-bootstrap PATH >>>$/ { skip=1; next }
        /^# <<< rootless-nix-bootstrap PATH <<</ { skip=0; next }
        !skip { print }
    ' "$HOME/.bashrc" > "$tmp"
    cat "$tmp" > "$HOME/.bashrc"
    rm -f "$tmp"
fi

rm -rf "$config_dir" "$share_dir"

echo "Removed rootless-nix-bootstrap wrappers and configuration."

if ((purge_store)); then
    if [[ "${RNB_MANAGED:-0}" != 1 ]]; then
        echo "Refusing to purge: store is not marked as managed by this bootstrap." >&2
        exit 1
    fi
    if [[ "$RNB_BACKEND" == user-chroot ]]; then
        rm -rf -- "$RNB_STORE_ROOT"
        [[ "${RNB_PROFILE_PREEXISTED:-1}" == 0 ]] && rm -rf -- "$HOME/.nix-profile"
        [[ "${RNB_DEFEXPR_PREEXISTED:-1}" == 0 ]] && rm -rf -- "$HOME/.nix-defexpr"
        [[ "${RNB_CHANNELS_PREEXISTED:-1}" == 0 ]] && rm -rf -- "$HOME/.nix-channels"
        echo "Purged managed Nix store: $RNB_STORE_ROOT"
    elif [[ "$RNB_BACKEND" == portable ]]; then
        rm -rf -- "$RNB_STORE_ROOT/.nix-portable"
        echo "Purged nix-portable state under: $RNB_STORE_ROOT/.nix-portable"
    fi
else
    echo "The Nix store was preserved. Re-run with --purge-store to remove it explicitly."
fi
