#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

write_state() {
    local home=$1 config_home=$2 store_root=$3 managed=${4:-1} nix_state_preexisted=${5:-0}
    local nix_state_dir="$home/.local/state/nix"
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
RNB_NIX_STATE_DIR=$nix_state_dir
RNB_NIX_STATE_PREEXISTED=$nix_state_preexisted
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

# Regular uninstall removes wrappers/helper files/PATH block but preserves both
# the store and state.env so a later purge or reinstall retains original
# ownership metadata.
home="$tmp_root/preserve-home"
config="$tmp_root/preserve-config"
store="$home/.nix"
state_file="$config/rootless-nix-bootstrap/state.env"
mkdir -p "$store/store/fake-package/bin"
touch "$store/store/fake-package/bin/tool"
write_state "$home" "$config" "$store"
env HOME="$home" XDG_CONFIG_HOME="$config" "$repo_root/uninstall.sh"
[[ -d "$store" ]]
[[ ! -e "$home/.local/bin/nix" ]]
[[ ! -e "$home/.local/bin/rootless-nix-doctor" ]]
[[ -r "$state_file" ]]
[[ ! -e "$home/.local/share/rootless-nix-bootstrap" ]]
# Confirm that the preserved metadata still identifies bootstrap-owned artifacts
# without executing the generated state file as shell code.
grep -qx 'RNB_MANAGED=1' "$state_file"
grep -qx 'RNB_PROFILE_PREEXISTED=0' "$state_file"
grep -qx 'RNB_DEFEXPR_PREEXISTED=0' "$state_file"
grep -qx 'RNB_CHANNELS_PREEXISTED=0' "$state_file"
grep -qx 'RNB_NIX_STATE_PREEXISTED=0' "$state_file"
if grep -Fq 'rootless-nix-bootstrap PATH' "$home/.bashrc"; then
    echo 'managed PATH block was not removed' >&2
    exit 1
fi
grep -qx 'before' "$home/.bashrc"
grep -qx 'after' "$home/.bashrc"

# A later purge must still work using the metadata preserved by ordinary
# uninstall, rather than requiring a reinstall first.
env HOME="$home" XDG_CONFIG_HOME="$config" "$repo_root/uninstall.sh" --purge-store
[[ ! -e "$store" ]]
[[ ! -e "$config/rootless-nix-bootstrap" ]]

# Purge must remove a Nix-like read-only store, bootstrap-created profile links,
# and the Nix state directory when the bootstrap created it.
home="$tmp_root/purge-home"
config="$tmp_root/purge-config"
store="$home/.nix"
nix_state="$home/.local/state/nix"
mkdir -p "$store/store/fake-package/bin" "$store/var/nix" "$home/.nix-profile" "$home/.nix-defexpr" "$nix_state/profiles"
touch "$store/store/fake-package/bin/tool" "$store/var/nix/db.sqlite" "$home/.nix-channels"
ln -s profile-1-link "$nix_state/profiles/profile"
ln -s /nix/store/fake-user-environment "$nix_state/profiles/profile-1-link"
chmod -R a-w "$store/store/fake-package"
write_state "$home" "$config" "$store"
env HOME="$home" XDG_CONFIG_HOME="$config" "$repo_root/uninstall.sh" --purge-store
[[ ! -e "$store" ]]
[[ ! -e "$home/.nix-profile" ]]
[[ ! -e "$home/.nix-defexpr" ]]
[[ ! -e "$home/.nix-channels" ]]
[[ ! -e "$nix_state" ]]
[[ ! -e "$config/rootless-nix-bootstrap" ]]
[[ ! -e "$home/.local/bin/nix" ]]

# A pre-existing Nix state directory must be preserved.
home="$tmp_root/preexisting-state-home"
config="$tmp_root/preexisting-state-config"
store="$home/.nix"
nix_state="$home/.local/state/nix"
mkdir -p "$store/store/fake-package" "$nix_state"
touch "$nix_state/keep-me"
write_state "$home" "$config" "$store" 1 1
env HOME="$home" XDG_CONFIG_HOME="$config" "$repo_root/uninstall.sh" --purge-store
[[ -e "$nix_state/keep-me" ]]

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

# A symlink-managed .bashrc must never be rewritten through the symlink.
home="$tmp_root/symlink-bashrc-home"
config="$tmp_root/symlink-bashrc-config"
store="$home/.nix"
dotfiles="$tmp_root/dotfiles"
mkdir -p "$home" "$dotfiles" "$store/store/fake-package"
cat > "$dotfiles/bashrc" <<'EOF_DOT_BASHRC'
managed-by-dotfiles
# >>> rootless-nix-bootstrap PATH >>>
export PATH="/example/.local/bin:$PATH"
# <<< rootless-nix-bootstrap PATH <<<
EOF_DOT_BASHRC
ln -s "$dotfiles/bashrc" "$home/.bashrc"
write_state "$home" "$config" "$store"
env HOME="$home" XDG_CONFIG_HOME="$config" "$repo_root/uninstall.sh"
grep -qx 'managed-by-dotfiles' "$dotfiles/bashrc"
grep -Fq 'rootless-nix-bootstrap PATH' "$dotfiles/bashrc"
[[ -L "$home/.bashrc" ]]

# Invalid uninstall options are rejected rather than silently ignored.
set +e
output=$(env HOME="$home" XDG_CONFIG_HOME="$config" "$repo_root/uninstall.sh" --unknown 2>&1)
rc=$?
set -e
[[ "$rc" -eq 2 ]]
[[ "$output" == *'Usage: ./uninstall.sh [--purge-store]'* ]]

echo 'Uninstall regression tests passed.'
