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
store_root="${RNB_STORE_ROOT:-$HOME/.nix}"
bin_dir="${RNB_BIN_DIR:-$HOME/.local/bin}"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/rootless-nix-bootstrap"
share_dir="${XDG_DATA_HOME:-$HOME/.local/share}/rootless-nix-bootstrap"

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

profile_preexisted=0
defexpr_preexisted=0
channels_preexisted=0
[[ -e "$HOME/.nix-profile" || -L "$HOME/.nix-profile" ]] && profile_preexisted=1
[[ -e "$HOME/.nix-defexpr" || -L "$HOME/.nix-defexpr" ]] && defexpr_preexisted=1
[[ -e "$HOME/.nix-channels" || -L "$HOME/.nix-channels" ]] && channels_preexisted=1

case "$backend" in
    user-chroot)
        backend_bin=$(rnb_install_user_chroot_binary "$arch" "$share_dir/bin" "$RNB_NIX_USER_CHROOT_VERSION")
        rnb_install_nix_in_chroot "$backend_bin" "$store_root" "$RNB_NIX_VERSION"
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

state_file="$config_dir/state.env"
rnb_write_state "$state_file" "$backend" "$store_root" "$backend_bin" "$bin_dir"
printf 'RNB_PROFILE_PREEXISTED=%q\nRNB_DEFEXPR_PREEXISTED=%q\nRNB_CHANNELS_PREEXISTED=%q\n' \
    "$profile_preexisted" "$defexpr_preexisted" "$channels_preexisted" >> "$state_file"
install -m 0755 "$REPO_ROOT/bin/nix" "$bin_dir/nix"
install -m 0755 "$REPO_ROOT/doctor.sh" "$bin_dir/rootless-nix-doctor"

path_changed=0
if ! rnb_path_contains "$bin_dir"; then
    bashrc="$HOME/.bashrc"
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

export PATH="$bin_dir:$PATH"

rnb_info "Verifying installation"
nix --version
nix eval --expr '1 + 1' >/dev/null

printf '\nInstalled rootless Nix backend: %s\n' "$backend"
printf 'Wrapper: %s/nix\n' "$bin_dir"
printf 'Store/location: %s\n' "$store_root"
printf '\nNext: cd <project> && nix develop\n'
if ((path_changed)); then
    printf 'Open a new Bash shell (or run: source ~/.bashrc) before using nix elsewhere.\n'
fi
printf 'Diagnostics: rootless-nix-doctor\n'
