#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

write_state() {
    local home=$1 config_home=$2 store_root=$3 managed=${4:-1}
    mkdir -p "$config_home/rootless-nix-bootstrap" "$home/.local/bin" "$home/.local/share/rootless-nix-bootstrap"
    cat > "$config_home/rootless-nix-bootstrap/state.env" <<EOF_STATE
RNB_BACKEND=user-chroot
RNB_STORE_ROOT=$store_root
RNB_BACKEND_BIN=$home/.local/share/rootless-nix-bootstrap/bin/nix-user-chroot
RNB_BIN_DIR=$home/.local/bin
RNB_MANAGED=$managed
RNB_PROFILE_PREEXISTED=0
RNB_DEFEXPR_PREEXISTED=0
RNB_CHANNELS_PREEXISTED=0
EOF_STATE
    cp "$repo_root/bin/nix" "$home/.local/bin/nix"
    cp "$repo_root/doctor.sh" "$home/.local/bin/rootless-nix-doctor"
    cat > "$home/.bashrc" <<EOF_BASHRC
before
# >>> rootless-nix-bootstrap PATH >>>
export PATH="$home/.local/bin:\$PATH"
# <<< rootless-nix-bootstrap PATH <<<
after
EOF_BASHRC
}

# Regular uninstall removes wrappers/configuration/PATH block but preserves store.
home="$tmp_root/preserve-home"
config="$tmp_root/preserve-config"
store="$home/.nix"
mkdir -p "$store/store/fake-package/bin"
touch "$store/store/fake-package/bin/tool"
write_state "$home" "$config" "$store"
env HOME="$home" XDG_CONFIG_HOME="$config" "$repo_root/uninstall.sh"
[[ -d "$store" ]]
[[ ! -e "$home/.local/bin/nix" ]]
[[ ! -e "$home/.local/bin/rootless-nix-doctor" ]]
[[ ! -e "$config/rootless-nix-bootstrap" ]]
[[ ! -e "$home/.local/share/rootless-nix-bootstrap" ]]
if grep -Fq 'rootless-nix-bootstrap PATH' "$home/.bashrc"; then
    echo 'managed PATH block was not removed' >&2
    exit 1
fi
grep -qx 'before' "$home/.bashrc"
grep -qx 'after' "$home/.bashrc"

# Purge must remove a Nix-like read-only store and bootstrap-created profile links.
home="$tmp_root/purge-home"
config="$tmp_root/purge-config"
store="$home/.nix"
mkdir -p "$store/store/fake-package/bin" "$store/var/nix" "$home/.nix-profile" "$home/.nix-defexpr"
touch "$store/store/fake-package/bin/tool" "$store/var/nix/db.sqlite" "$home/.nix-channels"
chmod -R a-w "$store/store/fake-package"
write_state "$home" "$config" "$store"
env HOME="$home" XDG_CONFIG_HOME="$config" "$repo_root/uninstall.sh" --purge-store
[[ ! -e "$store" ]]
[[ ! -e "$home/.nix-profile" ]]
[[ ! -e "$home/.nix-defexpr" ]]
[[ ! -e "$home/.nix-channels" ]]
[[ ! -e "$config/rootless-nix-bootstrap" ]]
[[ ! -e "$home/.local/bin/nix" ]]

# Purge must refuse stores that are not explicitly marked as managed.
home="$tmp_root/unmanaged-home"
config="$tmp_root/unmanaged-config"
store="$home/.nix"
mkdir -p "$store/store/keep-me"
write_state "$home" "$config" "$store" 0
set +e
env HOME="$home" XDG_CONFIG_HOME="$config" "$repo_root/uninstall.sh" --purge-store >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 1 ]]
[[ -d "$store" ]]
[[ -r "$config/rootless-nix-bootstrap/state.env" ]]

# If preparing the store for purge fails, state and wrappers must remain so the
# user can fix the host issue and retry instead of being left half-uninstalled.
home="$tmp_root/retry-home"
config="$tmp_root/retry-config"
store="$home/.nix"
mockbin="$tmp_root/retry-mockbin"
mkdir -p "$store/store/fake-package" "$mockbin"
write_state "$home" "$config" "$store"
cat > "$mockbin/chmod" <<'EOF_CHMOD'
#!/usr/bin/env bash
exit 1
EOF_CHMOD
chmod +x "$mockbin/chmod"
set +e
env HOME="$home" XDG_CONFIG_HOME="$config" PATH="$mockbin:/usr/bin:/bin" \
    "$repo_root/uninstall.sh" --purge-store >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 1 ]]
[[ -d "$store" ]]
[[ -r "$config/rootless-nix-bootstrap/state.env" ]]
[[ -e "$home/.local/bin/nix" ]]
[[ -e "$home/.local/bin/rootless-nix-doctor" ]]

# Invalid uninstall options are rejected rather than silently ignored.
set +e
output=$(env HOME="$home" XDG_CONFIG_HOME="$config" "$repo_root/uninstall.sh" --unknown 2>&1)
rc=$?
set -e
[[ "$rc" -eq 2 ]]
[[ "$output" == *'Usage: ./uninstall.sh [--purge-store]'* ]]

echo 'Uninstall regression tests passed.'
