#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_root=$(mktemp -d)
original_path=$PATH
trap 'PATH="$original_path"; chmod -R u+w "$tmp_root" 2>/dev/null || true; rm -rf "$tmp_root"' EXIT

# shellcheck disable=SC1091
source "$repo_root/lib/common.sh"
# shellcheck disable=SC1091
source "$repo_root/lib/detect.sh"
# shellcheck disable=SC1091
source "$repo_root/lib/gpu.sh"
# shellcheck disable=SC1091
source "$repo_root/lib/user-chroot.sh"

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
if rnb_path_contains /bet; then
    echo 'partial PATH element matched unexpectedly' >&2
    exit 1
fi
PATH=$original_path

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
PATH=$original_path

# GPU configuration is a no-op when nvidia-smi is absent. A PATH containing
# ordinary core utilities but no nvidia-smi exercises that branch.
emptybin="$tmp_root/emptybin"
mkdir -p "$emptybin"
PATH="$emptybin:/usr/bin:/bin"
rnb_configure_gpu_user_chroot "$tmp_root/no-gpu-store"
[[ ! -e "$tmp_root/no-gpu-store/var/nix/opengl-driver/lib/libcuda.so.1" ]]
PATH=$original_path

# The runtime probe must use the same parent filesystem as the requested store,
# clean up its temporary root, and propagate backend success/failure.
probe_parent="$tmp_root/probe-parent"
mkdir -p "$probe_parent"
probe_backend="$tmp_root/probe-backend"
cat > "$probe_backend" <<'EOF_PROBE_OK'
#!/usr/bin/env bash
root=$1
shift
[[ -d "$root" ]] || exit 9
exec "$@"
EOF_PROBE_OK
chmod +x "$probe_backend"
rnb_user_chroot_runtime_works "$probe_backend" "$probe_parent/.nix"
if compgen -G "$probe_parent/.rnb-probe.*" >/dev/null; then
    echo 'runtime probe left a temporary root behind' >&2
    exit 1
fi

# The compatibility probe must add --root-method chroot while keeping the same
# temporary-root placement and cleanup semantics.
cat > "$probe_backend" <<'EOF_PROBE_CHROOT'
#!/usr/bin/env bash
[[ "${1:-}" == --root-method ]] || exit 31
[[ "${2:-}" == chroot ]] || exit 32
root=$3
shift 3
[[ -d "$root" ]] || exit 33
exec "$@"
EOF_PROBE_CHROOT
chmod +x "$probe_backend"
rnb_user_chroot_runtime_works "$probe_backend" "$probe_parent/.nix" chroot
if compgen -G "$probe_parent/.rnb-probe.*" >/dev/null; then
    echo 'chroot runtime probe left a temporary root behind' >&2
    exit 1
fi

cat > "$probe_backend" <<'EOF_PROBE_FAIL'
#!/usr/bin/env bash
exit 23
EOF_PROBE_FAIL
chmod +x "$probe_backend"
set +e
rnb_user_chroot_runtime_works "$probe_backend" "$probe_parent/.nix"
rc=$?
set -e
[[ "$rc" -eq 23 ]]
if compgen -G "$probe_parent/.rnb-probe.*" >/dev/null; then
    echo 'failed runtime probe left a temporary root behind' >&2
    exit 1
fi

echo 'Helper function tests passed.'
