#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_root=$(mktemp -d)
trap 'chmod -R u+w "$tmp_root" 2>/dev/null || true; rm -rf "$tmp_root"' EXIT

# shellcheck source=../lib/common.sh
source "$repo_root/lib/common.sh"
# shellcheck source=../lib/detect.sh
source "$repo_root/lib/detect.sh"
# shellcheck source=../lib/gpu.sh
source "$repo_root/lib/gpu.sh"

# SHA-256 calculation and verification.
printf 'rootless-nix-bootstrap\n' > "$tmp_root/data"
expected=$(sha256sum "$tmp_root/data" | awk '{print $1}')
[[ "$(rnb_sha256 "$tmp_root/data")" == "$expected" ]]
rnb_verify_sha256 "$tmp_root/data" "$expected"

# State serialization must round-trip paths containing spaces.
state_file="$tmp_root/config/state.env"
rnb_write_state "$state_file" user-chroot "$tmp_root/store with spaces" "$tmp_root/backend" "$tmp_root/bin dir"
# shellcheck disable=SC1090
source "$state_file"
[[ "$RNB_BACKEND" == user-chroot ]]
[[ "$RNB_STORE_ROOT" == "$tmp_root/store with spaces" ]]
[[ "$RNB_BACKEND_BIN" == "$tmp_root/backend" ]]
[[ "$RNB_BIN_DIR" == "$tmp_root/bin dir" ]]
[[ "$RNB_MANAGED" == 1 ]]

# Current GitHub/Linux architecture must resolve to a supported canonical name.
arch=$(rnb_detect_arch)
[[ "$arch" == x86_64 || "$arch" == aarch64 ]]

# PATH membership must match whole path elements only.
PATH="/alpha:/beta:/gamma"
rnb_path_contains /beta
! rnb_path_contains /bet

# Filesystem detection should return a non-empty value for an existing path.
fs_type=$(rnb_filesystem_type "$tmp_root")
[[ -n "$fs_type" ]]

# Library detection should honor ldconfig output when a matching library exists.
mockbin="$tmp_root/mockbin"
libdir="$tmp_root/libs"
mkdir -p "$mockbin" "$libdir"
touch "$libdir/libcuda.so.1"
cat > "$mockbin/ldconfig" <<EOF_LDCONFIG
#!/usr/bin/env bash
cat <<'EOF_OUTPUT'
libcuda.so.1 (libc6,x86-64) => $libdir/libcuda.so.1
EOF_OUTPUT
EOF_LDCONFIG
chmod +x "$mockbin/ldconfig"
PATH="$mockbin:/usr/bin:/bin"
[[ "$(rnb_find_library libcuda.so.1)" == "$libdir/libcuda.so.1" ]]

# GPU configuration is a no-op when nvidia-smi is absent.
emptybin="$tmp_root/emptybin"
mkdir -p "$emptybin"
PATH="$emptybin:/usr/bin:/bin"
rnb_configure_gpu_user_chroot "$tmp_root/no-gpu-store"
[[ ! -e "$tmp_root/no-gpu-store/var/nix/opengl-driver/lib/libcuda.so.1" ]]

echo 'Helper function tests passed.'
