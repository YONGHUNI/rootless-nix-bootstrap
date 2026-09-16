# shellcheck shell=bash

rnb_find_library() {
    local soname=$1 candidate

    if rnb_have ldconfig; then
        candidate=$(ldconfig -p 2>/dev/null | awk -v lib="$soname" '$1 == lib { print $NF; exit }')
        if [[ -n "$candidate" && -e "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi

    for candidate in \
        "/usr/lib/x86_64-linux-gnu/$soname" \
        "/usr/lib/aarch64-linux-gnu/$soname" \
        "/usr/lib64/$soname" \
        "/usr/lib/$soname"; do
        if [[ -e "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

rnb_configure_gpu_user_chroot() {
    local store_root=$1 driver_dir lib src
    rnb_have nvidia-smi || return 0

    driver_dir="$store_root/var/nix/opengl-driver/lib"
    mkdir -p "$driver_dir"

    for lib in libcuda.so.1 libnvidia-ml.so.1; do
        if src=$(rnb_find_library "$lib"); then
            ln -sfn "$src" "$driver_dir/$lib"
            rnb_ok "GPU bridge: $lib -> $src"
        else
            rnb_warn "NVIDIA detected, but $lib was not found on the host"
        fi
    done
}
