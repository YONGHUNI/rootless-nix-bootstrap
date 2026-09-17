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

rnb_user_chroot_runtime_works() {
    local backend_bin=$1 store_root=$2 store_parent probe_root rc

    store_parent=$(dirname "$store_root")
    mkdir -p "$store_parent" || return 1
    store_parent=$(cd "$store_parent" && pwd -P) || return 1

    probe_root=$(mktemp -d "$store_parent/.rnb-probe.XXXXXX") || return 1
    chmod 0755 "$probe_root" || {
        rm -rf -- "$probe_root"
        return 1
    }

    if "$backend_bin" "$probe_root" bash -c 'true' >/dev/null 2>&1; then
        rc=0
    else
        rc=$?
    fi

    rm -rf -- "$probe_root"
    return "$rc"
}

rnb_install_nix_in_chroot() {
    local chroot_bin=$1 store_root=$2 nix_version=$3

    mkdir -p "$store_root"
    chmod 0755 "$store_root"

    # HOME must expand in the inner Bash running inside the chroot.
    # shellcheck disable=SC2016
    if "$chroot_bin" "$store_root" bash -c 'test -x "$HOME/.nix-profile/bin/nix" && "$HOME/.nix-profile/bin/nix" --version >/dev/null 2>&1'; then
        rnb_ok "Nix is already installed in the rootless store"
        return
    fi

    rnb_info "Installing pinned Nix ${nix_version} into the rootless store"
    "$chroot_bin" "$store_root" bash -c \
        'export NIX_INSTALLER_NO_MODIFY_PROFILE=1; curl --fail --location --proto "=https" --tlsv1.2 "https://releases.nixos.org/nix/nix-'"$nix_version"'/install" | sh -s -- --no-daemon --no-modify-profile'

    # shellcheck disable=SC2016
    "$chroot_bin" "$store_root" bash -c 'test -x "$HOME/.nix-profile/bin/nix"' || \
        rnb_die "Nix installation completed but ~/.nix-profile/bin/nix was not found"
}

rnb_probe_nix_sandbox() {
    local store_root=$1 arch=$2 candidate='' store_object='' builder_rel='' probe_name probe_expr

    # Reuse a shell that is already present in the freshly installed Nix
    # closure so the sandbox probe itself does not fetch nixpkgs. Some Nix
    # releases include Bash here, while a fresh install may contain only the
    # BusyBox /bin/sh used by Nix's sandbox defaults.
    for candidate in "$store_root"/store/*bash*/bin/bash; do
        [[ -x "$candidate" ]] || continue
        builder_rel='bin/bash'
        break
    done

    if [[ -z "$builder_rel" ]]; then
        for candidate in "$store_root"/store/*busybox*/bin/sh; do
            [[ -x "$candidate" ]] || continue
            builder_rel='bin/sh'
            break
        done
    fi

    [[ -n "$builder_rel" ]] || return 2

    store_object="/nix/store/${candidate#"$store_root/store/"}"
    store_object=${store_object%/"$builder_rel"}

    probe_name="rnb-sandbox-probe-${RANDOM}-${RANDOM}"
    probe_expr="let shell = builtins.storePath ${store_object}; in derivation { name = \"${probe_name}\"; system = \"${arch}-linux\"; builder = \"\${shell}/${builder_rel}\"; args = [ \"-c\" \"printf sandbox-ok > \$out\" ]; }"

    nix build --impure --no-link --option sandbox true --expr "$probe_expr" >/dev/null 2>&1
}
