#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_ROOT/lib/common.sh"

purge_store=0
case "${1:-}" in
    '') ;;
    --purge-store) purge_store=1 ;;
    *)
        echo "Usage: ./uninstall.sh [--purge-store]" >&2
        exit 2
        ;;
esac

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

# Purge the managed store before deleting state/helper files. Nix store paths are
# intentionally read-only, so make their directories owner-writable first.
# If this fails, keep the bootstrap state intact so the purge can be retried.
if ((purge_store)); then
    if [[ "${RNB_MANAGED:-0}" != 1 ]]; then
        echo "Refusing to purge: store is not marked as managed by this bootstrap." >&2
        exit 1
    fi

    if [[ "$RNB_BACKEND" == user-chroot ]]; then
        if [[ -d "$RNB_STORE_ROOT" ]]; then
            echo "Preparing managed Nix store for removal: $RNB_STORE_ROOT"
            if ! find "$RNB_STORE_ROOT" -type d -exec chmod u+w -- {} +; then
                echo "Failed to make managed Nix store directories writable; state was preserved." >&2
                exit 1
            fi
            if ! rm -rf -- "$RNB_STORE_ROOT"; then
                echo "Failed to remove managed Nix store; state was preserved." >&2
                exit 1
            fi
        fi

        [[ "${RNB_PROFILE_PREEXISTED:-1}" == 0 ]] && rm -rf -- "$HOME/.nix-profile"
        [[ "${RNB_DEFEXPR_PREEXISTED:-1}" == 0 ]] && rm -rf -- "$HOME/.nix-defexpr"
        [[ "${RNB_CHANNELS_PREEXISTED:-1}" == 0 ]] && rm -rf -- "$HOME/.nix-channels"
        if [[ "${RNB_NIX_STATE_PREEXISTED:-1}" == 0 && -n "${RNB_NIX_STATE_DIR:-}" ]]; then
            rm -rf -- "$RNB_NIX_STATE_DIR"
        fi
        echo "Purged managed Nix store: $RNB_STORE_ROOT"
    elif [[ "$RNB_BACKEND" == portable ]]; then
        portable_root="$RNB_STORE_ROOT/.nix-portable"
        if [[ -d "$portable_root" ]]; then
            echo "Preparing nix-portable state for removal: $portable_root"
            if ! find "$portable_root" -type d -exec chmod u+w -- {} +; then
                echo "Failed to make nix-portable directories writable; state was preserved." >&2
                exit 1
            fi
            if ! rm -rf -- "$portable_root"; then
                echo "Failed to remove nix-portable state; state was preserved." >&2
                exit 1
            fi
        fi
        echo "Purged nix-portable state under: $portable_root"
    fi
fi

for f in "$bin_dir/nix" "$bin_dir/rootless-nix-doctor"; do
    if [[ -f "$f" ]] && grep -q 'rootless-nix-bootstrap' "$f" 2>/dev/null; then
        rm -f "$f"
    fi
done

bashrc="$HOME/.bashrc"
path_action=$(rnb_remove_bashrc_path_block "$bashrc")
case "$path_action" in
    removed|absent) ;;
    symlink)
        echo "Leaving symlink-managed $bashrc untouched." >&2
        ;;
    unsupported)
        echo "Leaving non-regular $bashrc untouched." >&2
        ;;
    malformed)
        echo "Leaving $bashrc untouched because its rootless-nix-bootstrap PATH markers are malformed." >&2
        ;;
    *)
        echo "Failed to inspect or update $bashrc; bootstrap state was preserved." >&2
        exit 1
        ;;
esac

rm -rf "$share_dir"

if ((purge_store)); then
    rm -rf "$config_dir"
    echo "Removed rootless-nix-bootstrap wrappers and configuration."
else
    # The store is deliberately preserved, so retain state.env as purge
    # metadata. Besides allowing a later --purge-store, bootstrap also uses
    # these original ownership flags after reinstall so it does not mistake
    # bootstrap-created Nix profile/state artifacts for pre-existing user data.
    echo "Removed rootless-nix-bootstrap wrappers and helper files."
    echo "The Nix store and purge metadata were preserved. Re-run with --purge-store to remove them explicitly."
fi
