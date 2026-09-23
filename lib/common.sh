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

RNB_PATH_BLOCK_START='# >>> rootless-nix-bootstrap PATH >>>'
RNB_PATH_BLOCK_END='# <<< rootless-nix-bootstrap PATH <<<'

# Print one of: absent, managed, malformed.
# A managed block is valid only when every start marker has one later end marker,
# blocks do not nest, and no end marker appears outside a block.
rnb_path_block_state() {
    local file=$1
    awk -v start="$RNB_PATH_BLOCK_START" -v end="$RNB_PATH_BLOCK_END" '
        BEGIN {
            inside = 0
            pairs = 0
            malformed = 0
        }
        $0 == start {
            if (inside) {
                malformed = 1
            }
            inside = 1
            next
        }
        $0 == end {
            if (!inside) {
                malformed = 1
            } else {
                inside = 0
                pairs++
            }
            next
        }
        END {
            if (inside) {
                malformed = 1
            }
            if (malformed) {
                print "malformed"
            } else if (pairs > 0) {
                print "managed"
            } else {
                print "absent"
            }
        }
    ' "$file"
}

# Ensure the bootstrap PATH block exists in a regular Bash rc file.
# Print one of: added, present, symlink, unsupported, malformed.
# Symlinks and non-regular files are deliberately never followed or replaced.
rnb_add_bashrc_path_block() {
    local bashrc=$1 bin_dir=$2 state

    if [[ -L "$bashrc" ]]; then
        printf 'symlink\n'
        return 0
    fi
    if [[ -e "$bashrc" && ! -f "$bashrc" ]]; then
        printf 'unsupported\n'
        return 0
    fi

    touch "$bashrc" || return 1
    state=$(rnb_path_block_state "$bashrc") || return 1
    case "$state" in
        managed)
            printf 'present\n'
            ;;
        malformed)
            printf 'malformed\n'
            ;;
        absent)
            cat >> "$bashrc" <<EOF_PATH

$RNB_PATH_BLOCK_START
export PATH="$bin_dir:\$PATH"
$RNB_PATH_BLOCK_END
EOF_PATH
            printf 'added\n'
            ;;
        *)
            return 1
            ;;
    esac
}

# Remove only well-formed bootstrap PATH blocks from a regular Bash rc file.
# Print one of: removed, absent, symlink, unsupported, malformed.
# Malformed marker layouts are left byte-for-byte untouched rather than guessed.
rnb_remove_bashrc_path_block() {
    local bashrc=$1 state tmp

    if [[ -L "$bashrc" ]]; then
        printf 'symlink\n'
        return 0
    fi
    if [[ ! -e "$bashrc" ]]; then
        printf 'absent\n'
        return 0
    fi
    if [[ ! -f "$bashrc" ]]; then
        printf 'unsupported\n'
        return 0
    fi

    state=$(rnb_path_block_state "$bashrc") || return 1
    case "$state" in
        absent)
            printf 'absent\n'
            ;;
        malformed)
            printf 'malformed\n'
            ;;
        managed)
            tmp=$(mktemp) || return 1
            if ! awk -v start="$RNB_PATH_BLOCK_START" -v end="$RNB_PATH_BLOCK_END" '
                $0 == start { skip = 1; next }
                $0 == end { skip = 0; next }
                !skip { print }
            ' "$bashrc" > "$tmp"; then
                rm -f "$tmp"
                return 1
            fi
            if ! cat "$tmp" > "$bashrc"; then
                rm -f "$tmp"
                return 1
            fi
            rm -f "$tmp"
            printf 'removed\n'
            ;;
        *)
            return 1
            ;;
    esac
}
