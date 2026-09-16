# shellcheck shell=bash

rnb_install_user_chroot_binary() {
    local arch=$1 install_dir=$2 version=$3 expected url dest asset
    mkdir -p "$install_dir"

    case "$arch" in
        x86_64)
            asset="nix-user-chroot-bin-${version}-x86_64-unknown-linux-musl"
            expected=$RNB_NUC_SHA256_X86_64
            ;;
        aarch64)
            asset="nix-user-chroot-bin-${version}-aarch64-unknown-linux-musl"
            expected=$RNB_NUC_SHA256_AARCH64
            ;;
        *) rnb_die "Unsupported architecture: $arch" ;;
    esac

    dest="$install_dir/nix-user-chroot"
    url="https://github.com/nix-community/nix-user-chroot/releases/download/${version}/${asset}"

    if [[ -x "$dest" ]] && [[ "$(rnb_sha256 "$dest")" == "$expected" ]]; then
        rnb_ok "nix-user-chroot ${version} already installed"
        printf '%s\n' "$dest"
        return
    fi

    local tmp
    tmp=$(mktemp)
    rnb_info "Downloading nix-user-chroot ${version} (${arch})"
    rnb_download "$url" "$tmp"
    rnb_verify_sha256 "$tmp" "$expected"
    install -m 0755 "$tmp" "$dest"
    rm -f "$tmp"
    rnb_ok "Installed $dest"
    printf '%s\n' "$dest"
}

rnb_install_nix_in_chroot() {
    local chroot_bin=$1 store_root=$2 nix_version=$3

    mkdir -p "$store_root"
    chmod 0755 "$store_root"

    if "$chroot_bin" "$store_root" bash -c 'test -x "$HOME/.nix-profile/bin/nix" && "$HOME/.nix-profile/bin/nix" --version >/dev/null 2>&1'; then
        rnb_ok "Nix is already installed in the rootless store"
        return
    fi

    rnb_info "Installing pinned Nix ${nix_version} into the rootless store"
    "$chroot_bin" "$store_root" bash -c \
        'export NIX_INSTALLER_NO_MODIFY_PROFILE=1; curl --fail --location --proto "=https" --tlsv1.2 "https://releases.nixos.org/nix/nix-'"$nix_version"'/install" | sh -s -- --no-daemon --no-modify-profile'

    "$chroot_bin" "$store_root" bash -c 'test -x "$HOME/.nix-profile/bin/nix"' || \
        rnb_die "Nix installation completed but ~/.nix-profile/bin/nix was not found"
}
