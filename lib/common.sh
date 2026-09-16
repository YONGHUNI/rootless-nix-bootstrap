# shellcheck shell=bash

rnb_info() { printf '==> %s\n' "$*" >&2; }
rnb_ok()   { printf '[OK] %s\n' "$*" >&2; }
rnb_warn() { printf '[WARN] %s\n' "$*" >&2; }
rnb_die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

rnb_have() { command -v "$1" >/dev/null 2>&1; }

rnb_sha256() {
    if rnb_have sha256sum; then
        sha256sum "$1" | awk '{print $1}'
    elif rnb_have shasum; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        rnb_die "sha256sum or shasum is required"
    fi
}

rnb_download() {
    local url=$1 dest=$2
    rnb_have curl || rnb_die "curl is required for bootstrap downloads"
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$dest" "$url"
}

rnb_verify_sha256() {
    local file=$1 expected=$2 actual
    [[ -n "$expected" ]] || rnb_die "No pinned SHA-256 is available for $(basename "$file")"
    actual=$(rnb_sha256 "$file")
    [[ "$actual" == "$expected" ]] || rnb_die "SHA-256 mismatch for $(basename "$file"): expected $expected, got $actual"
}

rnb_write_state() {
    local file=$1 backend=$2 store_root=$3 backend_bin=$4 bin_dir=$5
    mkdir -p "$(dirname "$file")"
    {
        printf 'RNB_BACKEND=%q\n' "$backend"
        printf 'RNB_STORE_ROOT=%q\n' "$store_root"
        printf 'RNB_BACKEND_BIN=%q\n' "$backend_bin"
        printf 'RNB_BIN_DIR=%q\n' "$bin_dir"
        printf 'RNB_MANAGED=1\n'
    } > "$file"
    chmod 600 "$file"
}
