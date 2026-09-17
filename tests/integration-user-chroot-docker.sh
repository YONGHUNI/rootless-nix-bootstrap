#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

docker run --rm --privileged \
    --security-opt apparmor=unconfined \
    -v "$repo_root:/repo:ro" \
    ubuntu:24.04 \
    bash -lc '
        set -Eeuo pipefail
        apt-get update >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            ca-certificates curl xz-utils util-linux passwd findutils gawk grep coreutils tar >/dev/null
        useradd -m -s /bin/bash tester
        su - tester -s /bin/bash -c "cd /repo && bash tests/integration.sh user-chroot"
    '
