# shellcheck shell=bash

rnb_detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64\n' ;;
        aarch64|arm64) printf 'aarch64\n' ;;
        *) return 1 ;;
    esac
}

rnb_userns_works() {
    rnb_have unshare || return 1
    unshare --user --pid true >/dev/null 2>&1
}

rnb_existing_nix_works() {
    rnb_have nix || return 1
    nix --version >/dev/null 2>&1
}

rnb_path_contains() {
    case ":${PATH:-}:" in
        *":$1:"*) return 0 ;;
        *) return 1 ;;
    esac
}

rnb_filesystem_type() {
    local path=$1
    if stat -f -c '%T' "$path" >/dev/null 2>&1; then
        stat -f -c '%T' "$path"
    else
        printf 'unknown\n'
    fi
}
