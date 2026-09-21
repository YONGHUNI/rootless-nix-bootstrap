# shellcheck shell=bash
# shellcheck disable=SC2034
# Pinned bootstrap dependencies. These variables are consumed by sourced files.

RNB_NIX_VERSION="2.35.2"
RNB_NIX_USER_CHROOT_VERSION="2.1.1"
RNB_NIX_USER_CHROOT_COMPAT_VERSION="2.1.1-rnb1"
RNB_NIX_PORTABLE_VERSION="v012"

# SHA-256 digests published by the nix-user-chroot 2.1.1 GitHub release.
RNB_NUC_SHA256_X86_64="e6daa6a036e00b939531e5c11e6dcd891140813a09964fd12a64112de500fc15"
RNB_NUC_SHA256_AARCH64="9aeaa70f4fb645afb343b0417e494b0271457a8cb465c4ac82b6c3b19040d397"

# Compatibility build: upstream 2.1.1 plus an explicit --root-method chroot
# path. This is used only when the unmodified upstream runtime probe fails.
# The upstream binary remains the first choice and is unchanged on ordinary hosts.
RNB_NUC_COMPAT_SHA256_X86_64="c92f8492ea2038a2622dced91ab043b3949dff409757d4e3bff202f1e63d2685"
RNB_NUC_COMPAT_SHA256_AARCH64=""

# nix-portable v012 does not publish GitHub asset digests. The x86_64 digest
# below is independently recorded in upstream issue #139. The aarch64 fallback
# is therefore intentionally disabled until a digest is pinned here.
RNB_PORTABLE_SHA256_X86_64="b409c55904c909ac3aeda3fb1253319f86a89ddd1ba31a5dec33d4a06414c72a"
RNB_PORTABLE_SHA256_AARCH64=""
