#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
backend=${1:-user-chroot}
case "$backend" in
    user-chroot|portable) ;;
    *) echo "Usage: tests/integration.sh user-chroot|portable" >&2; exit 2 ;;
esac

tmp_root=$(mktemp -d)
trap 'chmod -R u+w "$tmp_root" 2>/dev/null || true; rm -rf "$tmp_root"' EXIT

export HOME="$tmp_root/home"
export XDG_CONFIG_HOME="$tmp_root/config"
export XDG_DATA_HOME="$tmp_root/data"
bin_dir="$HOME/.local/bin"
mkdir -p "$HOME" "$bin_dir"

# Prevent any runner-provided Nix from short-circuiting bootstrap while keeping
# all ordinary host utilities available.
original_path=$PATH
mask_bin="$tmp_root/mask-bin"
mkdir -p "$mask_bin"
cat > "$mask_bin/nix" <<'EOF_MASK'
#!/usr/bin/env bash
exit 127
EOF_MASK
chmod +x "$mask_bin/nix"
export PATH="$mask_bin:$original_path"

bootstrap() {
    case "$backend" in
        user-chroot)
            "$repo_root/bootstrap.sh" --backend user-chroot --store-root "$HOME/.nix" --bin-dir "$bin_dir"
            ;;
        portable)
            "$repo_root/bootstrap.sh" --backend portable --bin-dir "$bin_dir"
            ;;
    esac
    export PATH="$bin_dir:$mask_bin:$original_path"
}

assert_installed() {
    [[ -x "$bin_dir/nix" ]]
    [[ -x "$bin_dir/rootless-nix-doctor" ]]
    nix --version
    [[ "$(nix eval --expr '1 + 1')" == 2 ]]
    [[ "$(nix eval "path:$repo_root/tests/fixture#lib.smoke" --raw)" == ok ]]
    rootless-nix-doctor
}

# Fresh install and all primary commands.
bootstrap
assert_installed

if [[ "$backend" == user-chroot ]]; then
    nix config show | grep -q '^sandbox = '
    sandbox=$(nix config show | awk -F ' = ' '$1 == "sandbox" { print $2; exit }')
    if [[ "$sandbox" == true ]]; then
        [[ "$(nix config show | awk -F ' = ' '$1 == "sandbox-fallback" { print $2; exit }')" == false ]]
    fi
fi

# Bootstrap must be idempotent.
bootstrap
assert_installed

# Ordinary uninstall must remove command/configuration files but preserve the
# backend's expensive store/state payload.
case "$backend" in
    user-chroot) preserved="$HOME/.nix" ;;
    portable) preserved="$HOME/.nix-portable" ;;
esac
[[ -e "$preserved" ]]
"$repo_root/uninstall.sh"
[[ -e "$preserved" ]]
[[ ! -e "$bin_dir/nix" ]]
[[ ! -e "$XDG_CONFIG_HOME/rootless-nix-bootstrap" ]]

# Reinstall must reuse the preserved backend payload and become healthy again.
bootstrap
assert_installed

# Destructive uninstall must remove both bootstrap files and the managed store.
"$repo_root/uninstall.sh" --purge-store
[[ ! -e "$bin_dir/nix" ]]
[[ ! -e "$XDG_CONFIG_HOME/rootless-nix-bootstrap" ]]
[[ ! -e "$preserved" ]]

echo "Full integration lifecycle passed for backend: $backend"
