# shellcheck shell=bash
# Pinned bootstrap dependencies.

RNB_NIX_VERSION="2.35.2"
RNB_NIX_USER_CHROOT_VERSION="2.1.1"
RNB_NIX_PORTABLE_VERSION="v012"

# SHA-256 digests published by the nix-user-chroot 2.1.1 GitHub release.
RNB_NUC_SHA256_X86_64="e6daa6a036e00b939531e5c11e6dcd891140813a09964fd12a64112de500fc15"
RNB_NUC_SHA256_AARCH64="9aeaa70f4fb645afb343b0417e494b0271457a8cb465c4ac82b6c3b19040d397"

# nix-portable v012 does not publish GitHub asset digests. The x86_64 digest
# below is independently recorded in upstream issue #139. The aarch64 fallback
# is therefore intentionally disabled until a digest is pinned here.
RNB_PORTABLE_SHA256_X86_64="b409c55904c909ac3aeda3fb1253319f86a89ddd1ba31a5dec33d4a06414c72a"
RNB_PORTABLE_SHA256_AARCH64=""
