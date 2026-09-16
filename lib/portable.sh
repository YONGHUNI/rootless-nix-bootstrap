# shellcheck shell=bash

rnb_install_portable() {
    local arch=$1 install_dir=$2 version=$3 expected asset url dest tmp
    mkdir -p "$install_dir"

    case "$arch" in
        x86_64)
            asset="nix-portable-x86_64"
            expected=$RNB_PORTABLE_SHA256_X86_64
            ;;
        aarch64)
            asset="nix-portable-aarch64"
            expected=$RNB_PORTABLE_SHA256_AARCH64
            ;;
        *) rnb_die "Unsupported architecture: $arch" ;;
    esac

    [[ -n "$expected" ]] || rnb_die "nix-portable ${version} aarch64 is not enabled: no pinned upstream asset digest is available yet"

    dest="$install_dir/nix-portable"
    url="https://github.com/DavHau/nix-portable/releases/download/${version}/${asset}"

    if [[ -x "$dest" ]] && [[ "$(rnb_sha256 "$dest")" == "$expected" ]]; then
        rnb_ok "nix-portable ${version} already installed"
        printf '%s\n' "$dest"
        return
    fi

    tmp=$(mktemp)
    rnb_info "Downloading nix-portable ${version} (${arch})"
    rnb_download "$url" "$tmp"
    rnb_verify_sha256 "$tmp" "$expected"
    install -m 0755 "$tmp" "$dest"
    rm -f "$tmp"
    rnb_ok "Installed experimental nix-portable fallback"
    printf '%s\n' "$dest"
}
