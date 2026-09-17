#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

bash -n "$repo_root/bootstrap.sh"
bash -n "$repo_root/uninstall.sh"
bash -n "$repo_root/doctor.sh"
bash -n "$repo_root/bin/nix"
for f in "$repo_root"/lib/*.sh "$repo_root"/tests/*.sh; do
    [[ "$f" == "$repo_root/tests/smoke.sh" ]] && continue
    bash -n "$f"
done

echo "Shell syntax smoke test passed."
