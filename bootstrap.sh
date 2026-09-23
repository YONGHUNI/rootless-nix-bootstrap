#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=versions.sh
source "$REPO_ROOT/versions.sh"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$REPO_ROOT/lib/detect.sh"
# shellcheck source=lib/user-chroot.sh
source "$REPO_ROOT/lib/user-chroot.sh"
# shellcheck source=lib/portable.sh
source "$REPO_ROOT/lib/portable.sh"
# shellcheck source=lib/gpu.sh
source "$REPO_ROOT/lib/gpu.sh"

backend=auto
user_chroot_root_method=pivot
store_root="${RNB_STORE_ROOT:-$HOME/.nix}"
bin_dir="${RNB_BIN_DIR:-$HOME/.local/bin}"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/rootless-nix-bootstrap"
share_dir="${XDG_DATA_HOME:-$HOME/.local/share}/rootless-nix-bootstrap"
nix_state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/nix"

usage() {
    cat <<'USAGE'
Usage: ./bootstrap.sh [options]

Options:
  --backend auto|user-chroot|portable   Backend selection (default: auto)
  --store-root PATH                     Physical root for the user Nix store
  --bin-dir PATH                        Directory for the nix wrapper
  -h, --help                            Show this help

The host OS is not managed or replaced. This installs only enough rootless Nix
infrastructure to run project commands such as "nix develop".
USAGE
}

while (($#)); do
    case "$1" in
        --backend)
            [[ $# -ge 2 ]] || rnb_die "--backend requires an argument"
            backend=$2; shift 2 ;;
        --store-root)
            [[ $# -ge 2 ]] || rnb_die "--store-root requires an argument"
            store_root=$2; shift 2 ;;
        --bin-dir)
            [[ $# -ge 2 ]] || rnb_die "--bin-dir requires an argument"
            bin_dir=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) rnb_die "Unknown option: $1" ;;
    esac
done

[[ "$(uname -s)" == Linux ]] || rnb_die "Linux is required"
for required in curl tar xz awk grep install; do
    rnb_have "$required" || rnb_die "$required is required on the host"
done
arch=$(rnb_detect_arch) || rnb_die "Only x86_64 and aarch64 Linux are supported"

if rnb_existing_nix_works && [[ "$(command -v nix)" != "$bin_dir/nix" ]]; then
    rnb_ok "A working host Nix installation already exists: $(command -v nix)"
    nix --version
    rnb_info "Nothing to install. Existing Nix remains untouched."
    exit 0
fi

case "$backend" in
    auto)
        if rnb_userns_works; then
            backend=user-chroot
        else
            cat >&2 <<'MSG'
[WARN] Unprivileged user namespaces are unavailable or blocked.
       nix-user-chroot cannot be used on this host.
       The nix-portable/PRoot fallback has weaker host integration and may add
       substantial overhead, so it is not selected silently.
       Re-run with: ./bootstrap.sh --backend portable
MSG
            exit 2
        fi
        ;;
    user-chroot)
        rnb_userns_works || rnb_die "user-chroot requested, but unprivileged user namespaces are unavailable"
        ;;
    portable) ;;
    *) rnb_die "Invalid backend: $backend" ;;
esac

mkdir -p "$bin_dir" "$config_dir" "$share_dir/bin" "$store_root"
store_root=$(cd "$store_root" && pwd -P)
state_file="$config_dir/state.env"

# These flags describe whether upstream Nix profile/state artifacts existed
# before this bootstrap first managed the installation. Preserve that original
# ownership information across idempotent reruns instead of treating files
# created by the first run as user-preexisting files on later runs.
profile_preexisted=''
defexpr_preexisted=''
channels_preexisted=''
nix_state_preexisted=''
managed_nix_state_dir=''
if [[ -r "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file"
    if [[ "${RNB_MANAGED:-0}" == 1 ]]; then
        case "${RNB_PROFILE_PREEXISTED:-}" in 0|1) profile_preexisted=$RNB_PROFILE_PREEXISTED ;; esac
        case "${RNB_DEFEXPR_PREEXISTED:-}" in 0|1) defexpr_preexisted=$RNB_DEFEXPR_PREEXISTED ;; esac
        case "${RNB_CHANNELS_PREEXISTED:-}" in 0|1) channels_preexisted=$RNB_CHANNELS_PREEXISTED ;; esac
        case "${RNB_NIX_STATE_PREEXISTED:-}" in 0|1) nix_state_preexisted=$RNB_NIX_STATE_PREEXISTED ;; esac
        [[ -n "${RNB_NIX_STATE_DIR:-}" ]] && managed_nix_state_dir=$RNB_NIX_STATE_DIR
    fi
fi

if [[ -z "$profile_preexisted" ]]; then
    profile_preexisted=0
    [[ -e "$HOME/.nix-profile" || -L "$HOME/.nix-profile" ]] && profile_preexisted=1
fi
if [[ -z "$defexpr_preexisted" ]]; then
    defexpr_preexisted=0
    [[ -e "$HOME/.nix-defexpr" || -L "$HOME/.nix-defexpr" ]] && defexpr_preexisted=1
fi
if [[ -z "$channels_preexisted" ]]; then
    channels_preexisted=0
    [[ -e "$HOME/.nix-channels" || -L "$HOME/.nix-channels" ]] && channels_preexisted=1
fi
if [[ -z "$managed_nix_state_dir" ]]; then
    managed_nix_state_dir=$nix_state_dir
fi
if [[ -z "$nix_state_preexisted" ]]; then
    nix_state_preexisted=0
    [[ -e "$managed_nix_state_dir" || -L "$managed_nix_state_dir" ]] && nix_state_preexisted=1
fi

case "$backend" in
    user-chroot)
        # First try the unmodified upstream binary and its historical pivot_root
        # path. Hosts where this already works (for example ordinary cloud GPU
        # servers) keep exactly the same backend binary and invocation.
        backend_bin=$(rnb_install_user_chroot_binary "$arch" "$share_dir/bin" "$RNB_NIX_USER_CHROOT_VERSION")
        rnb_info "Probing upstream nix-user-chroot runtime support"
        if rnb_user_chroot_runtime_works "$backend_bin" "$store_root" pivot; then
            user_chroot_root_method=pivot
            rnb_ok "Upstream nix-user-chroot runtime probe succeeded"
        else
            rnb_warn "Upstream nix-user-chroot runtime probe failed; trying native chroot compatibility mode"
            compat_bin=$(rnb_install_user_chroot_compat_binary "$arch" "$share_dir/bin" "$RNB_NIX_USER_CHROOT_COMPAT_VERSION")
            if rnb_user_chroot_runtime_works "$compat_bin" "$store_root" chroot; then
                backend_bin=$compat_bin
                user_chroot_root_method=chroot
                rnb_ok "nix-user-chroot chroot compatibility probe succeeded"
            else
                rnb_die "nix-user-chroot failed with both the upstream pivot_root path and the native chroot compatibility path. Try: ./bootstrap.sh --backend portable"
            fi
        fi
        rnb_install_nix_in_chroot "$backend_bin" "$store_root" "$RNB_NIX_VERSION" "$user_chroot_root_method"
        mkdir -p "$store_root/etc/nix"
        install -m 0644 "$REPO_ROOT/config/nix.conf" "$store_root/etc/nix/nix.conf"
        fs_type=$(rnb_filesystem_type "$store_root")
        case "$fs_type" in
            nfs|nfs4)
                printf '\n# Required for a writable Nix store on NFS.\nuse-sqlite-wal = false\n' >> "$store_root/etc/nix/nix.conf"
                rnb_warn "NFS store detected; configured use-sqlite-wal = false"
                ;;
        esac
        rnb_configure_gpu_user_chroot "$store_root"
        ;;
    portable)
        rnb_warn "nix-portable is an experimental fallback; PRoot can be significantly slower"
        backend_bin=$(rnb_install_portable "$arch" "$share_dir/bin" "$RNB_NIX_PORTABLE_VERSION")
        store_root="${RNB_PORTABLE_LOCATION:-$HOME}"
        ;;
esac

rnb_write_state "$state_file" "$backend" "$store_root" "$backend_bin" "$bin_dir"
if [[ "$backend" == user-chroot ]]; then
    printf 'RNB_USER_CHROOT_ROOT_METHOD=%q\n' "$user_chroot_root_method" >> "$state_file"
fi
printf 'RNB_PROFILE_PREEXISTED=%q\nRNB_DEFEXPR_PREEXISTED=%q\nRNB_CHANNELS_PREEXISTED=%q\nRNB_NIX_STATE_DIR=%q\nRNB_NIX_STATE_PREEXISTED=%q\n' \
    "$profile_preexisted" "$defexpr_preexisted" "$channels_preexisted" "$managed_nix_state_dir" "$nix_state_preexisted" >> "$state_file"
install -m 0755 "$REPO_ROOT/bin/nix" "$bin_dir/nix"
install -m 0755 "$REPO_ROOT/doctor.sh" "$bin_dir/rootless-nix-doctor"

path_changed=0
path_shell_managed_elsewhere=0
if ! rnb_path_contains "$bin_dir"; then
    bashrc="$HOME/.bashrc"

    # A symlinked shell rc file is commonly owned by a dotfiles manager
    # (Home Manager, GNU Stow, a Git checkout, etc.). Writing through the
    # symlink would dirty or mutate that external configuration repository.
    # Leave it untouched and rely on the owner of the symlink to manage PATH.
    if [[ -L "$bashrc" ]]; then
        path_shell_managed_elsewhere=1
        rnb_warn "Not modifying symlink-managed $bashrc; ensure $bin_dir is added to PATH by your shell configuration"
    else
        touch "$bashrc"
        if ! grep -Fq '# >>> rootless-nix-bootstrap PATH >>>' "$bashrc"; then
            cat >> "$bashrc" <<EOF_PATH

# >>> rootless-nix-bootstrap PATH >>>
export PATH="$bin_dir:\$PATH"
# <<< rootless-nix-bootstrap PATH <<<
EOF_PATH
            path_changed=1
        fi
    fi
fi

export PATH="$bin_dir:$PATH"

rnb_info "Verifying installation"
nix --version
nix eval --expr '1 + 1' >/dev/null

if [[ "$backend" == user-chroot ]]; then
    rnb_info "Probing Nix build sandbox support"
    if rnb_probe_nix_sandbox "$store_root" "$arch"; then
        sed -i 's/^sandbox = false$/sandbox = true/' "$store_root/etc/nix/nix.conf"
        printf 'RNB_SANDBOX_SUPPORTED=1\n' >> "$state_file"
        rnb_ok "Nix build sandbox is supported and enabled"
    else
        printf 'RNB_SANDBOX_SUPPORTED=0\n' >> "$state_file"
        rnb_warn "Nix build sandbox is unavailable; continuing with sandbox = false"
    fi
fi

printf '\nInstalled rootless Nix backend: %s\n' "$backend"
if [[ "$backend" == user-chroot ]]; then
    printf 'Root method: %s\n' "$user_chroot_root_method"
fi
printf 'Wrapper: %s/nix\n' "$bin_dir"
printf 'Store/location: %s\n' "$store_root"
printf '\nNext: cd <project> && nix develop\n'
if ((path_changed)); then
    printf 'Open a new Bash shell (or run: source ~/.bashrc) before using nix elsewhere.\n'
elif ((path_shell_managed_elsewhere)); then
    printf 'Shell configuration was left untouched because ~/.bashrc is symlink-managed.\n'
fi
printf 'Diagnostics: rootless-nix-doctor\n'
