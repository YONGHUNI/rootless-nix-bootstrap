# rootless-nix-bootstrap

Use project-oriented Nix workflows on Linux machines where you do not control the host OS and may not have root access.

The project intentionally does **not** turn the host into NixOS and does not replace the login shell, Slurm, environment modules, system packages, the Linux kernel, or NVIDIA drivers. It adds a thin rootless `nix` command so repositories can keep using workflows such as:

```bash
cd my-project
nix develop
```

This is aimed first at cloud/Linux compute servers and is designed with shared-filesystem Slurm/HPC systems in mind.

## Scope

The responsibility boundary is:

```text
host administrator / cloud image
├── Linux kernel
├── system libraries and utilities
├── Slurm / modules
└── NVIDIA kernel driver

rootless-nix-bootstrap
└── permissionless `nix` command + user Nix store

project repository
├── flake.nix + flake.lock
└── pixi.toml + pixi.lock (when used)
```

The host stays a normal Linux host until a project explicitly invokes Nix.

## Supported systems

- Linux x86_64
- Linux aarch64
- Bash
- no root required

The preferred backend is [`nix-user-chroot`](https://github.com/nix-community/nix-user-chroot), which requires unprivileged user namespaces. The bootstrap first uses the unmodified upstream binary and its normal `pivot_root` path. If that runtime probe fails while user namespaces are available, it can use a pinned compatibility build that keeps the same namespace/bind-mount design but switches the final root transition to `chroot`. `nix-portable` remains an explicit last-resort fallback because its PRoot path can add significant overhead and has weaker host integration.

## Install

```bash
git clone https://github.com/YONGHUNI/rootless-nix-bootstrap.git
cd rootless-nix-bootstrap
./bootstrap.sh
```

If `~/.local/bin` is not already on `PATH`, bootstrap adds one small managed block to an ordinary regular `~/.bashrc`. Symlinks (including dangling symlinks), directories or other non-regular objects are never followed or replaced; this avoids mutating shell configuration owned by a dotfiles repository, GNU Stow, Home Manager, or another tool. If bootstrap finds malformed rootless-nix-bootstrap PATH markers, it also leaves the file unchanged rather than guessing which user lines belong to the managed block. In these cases it asks you to manage the PATH entry explicitly. It does not automatically enter a Nix shell at login.

The upstream Nix installer may print a generic suggestion to source `~/.nix-profile/etc/profile.d/nix.sh`. Do **not** add that line when using this bootstrap; the wrapper intentionally exposes Nix only when the `nix` command is invoked.

Then use Nix only where needed:

```bash
cd ~/projects/my-project
nix develop
```

For batch-style execution:

```bash
nix develop -c pixi run python analysis.py
```

### Store location

The default physical store root for `nix-user-chroot` is:

```text
~/.nix
```

Inside the rootless namespace it appears as the conventional `/nix`, so project flakes retain normal Nix store paths. On HPC systems with a small home quota, select a persistent shared filesystem instead:

```bash
./bootstrap.sh --store-root /path/to/persistent/shared/storage/.nix
```

Do not place a long-lived store on purgeable scratch storage unless that is intentional.

## Backend selection

Automatic mode first checks unprivileged user namespaces and then probes the unmodified upstream `nix-user-chroot` binary:

```bash
./bootstrap.sh
```

On hosts where the upstream runtime works, bootstrap keeps the original binary and invocation unchanged. If that runtime probe fails, bootstrap tries a pinned native compatibility build with `--root-method chroot`. This is intended for HPC/rootfs environments where user and mount namespaces plus bind mounts work but `pivot_root` does not. The selected method is recorded in `state.env` and shown by `rootless-nix-doctor`.

If user namespaces are blocked, or both native root methods fail, bootstrap stops rather than silently switching to a slower runtime. The optional PRoot fallback remains explicit:

```bash
./bootstrap.sh --backend portable
```

The current portable fallback is experimental. Its released bundle is older than the preferred backend and PRoot can impose substantial overhead. The chroot compatibility binary is currently pinned for x86_64; aarch64 continues to use the upstream `nix-user-chroot` path unless another fallback is selected explicitly.

## GPU hosts

When `nvidia-smi` is present, the `nix-user-chroot` backend links host `libcuda.so.1` (and `libnvidia-ml.so.1` when available) into the driver-library bridge expected by Nix software at `/run/opengl-driver/lib`.

For the `nix-user-chroot` backend, the `nix` wrapper adds that bridge to `LD_LIBRARY_PATH` only inside the wrapper process and its descendants when the bridge exists. It does not modify the login shell globally. This lets tools launched through workflows such as `nix develop` discover the host NVIDIA driver while keeping host-driver integration separate from project dependencies.

The bootstrap does **not** install CUDA Toolkit, cuDNN, JAX, PyTorch, or other research dependencies. Those belong in the project flake/Pixi environment. The NVIDIA kernel driver remains a host responsibility.

## Slurm / HPC

On clusters where the home or project filesystem is shared, the physical Nix store can be shared as well. Each compute-node invocation creates its own rootless namespace when the `nix` wrapper runs; the store contents do not need to be reinstalled per node. If the selected store is on NFS, bootstrap detects that case and sets `use-sqlite-wal = false`, as recommended for writable Nix stores on NFS. Filesystem/site policies still matter, especially under concurrent jobs.

For Slurm jobs, the wrapper also isolates **Nix's own user cache** from a shared home directory. It uses Nix's dedicated `NIX_CACHE_HOME` setting rather than changing `XDG_CACHE_HOME`, so caches belonging to Pixi, Python, Hugging Face, and other tools are unaffected. When the configured Nix store already resolves under node-local `/tmp` or `/var/tmp` storage, the cache is placed beside that store; otherwise the wrapper prefers `$SLURM_TMPDIR` and falls back to a user-private directory under `/tmp`. Jobs on the same node can reuse that local Nix cache, while jobs on different nodes do not concurrently write the same SQLite fetch cache in a shared home directory.

Explicit cache choices take precedence: an existing `NIX_CACHE_HOME` is never overridden, and `RNB_NIX_CACHE_HOME=/path` can be used as a bootstrap-specific override. Outside Slurm, Nix keeps its normal cache location. The wrapper also detects a configured node-local store that is absent on the current node and prints a recovery message instead of invoking the backend with a stale path.

Examples:

```bash
# interactive allocation
cd project
nix develop

# command execution
srun nix --version
srun nix develop -c python analysis.py
```

Whether a particular cluster permits user namespaces is site policy. Use `rootless-nix-doctor` to inspect the current host/node.

## Reproducibility boundary

This project makes a normal project Nix workflow available; it does not make the host OS reproducible. `flake.lock` still pins the Nix project inputs, and a project-specific lockfile such as `pixi.lock` can pin the application stack.

For the preferred `nix-user-chroot` backend, bootstrap starts conservatively with `sandbox = false` and then performs a small real Nix build with `--option sandbox true`. If that build succeeds, the installed configuration is changed to `sandbox = true`. If the host or cluster policy prevents sandboxed builds, bootstrap keeps `sandbox = false` and continues rather than making rootless Nix unusable.

When the sandbox is enabled, `sandbox-fallback = false` is also configured. A later sandbox failure therefore causes the Nix build to fail explicitly instead of silently continuing without sandbox isolation.

When enabled, the Nix build sandbox improves build isolation by preventing accidental dependencies on undeclared host files and tools. It applies to Nix builds; it does not independently sandbox Pixi environments or make the host kernel, drivers, or scheduler reproducible.

## Diagnostics

```bash
rootless-nix-doctor
```

The doctor checks the selected backend, Nix CLI, evaluator, flake support, user namespaces, the current Nix sandbox and fallback settings, and the NVIDIA driver bridge when relevant.

## Update

The bootstrap is idempotent. Update the repository and rerun it:

```bash
git pull --ff-only
./bootstrap.sh
```

This is separate from a project's:

```bash
nix flake update
```

which updates that project's flake inputs.

## Uninstall

Remove wrappers/configuration while preserving the potentially large Nix store:

```bash
./uninstall.sh
```

Explicitly remove the managed store as well:

```bash
./uninstall.sh --purge-store
```

The uninstaller removes only complete PATH blocks managed by this project and files recorded as bootstrap-managed. Symlinked or non-regular `~/.bashrc` objects, files without a managed block, and files with malformed managed markers are left untouched.

## Security / downloads

The preferred upstream `nix-user-chroot` release is version-pinned and verified against the SHA-256 digest published with its GitHub release. The optional chroot compatibility binary is built reproducibly from the pinned upstream 2.1.1 commit plus the small source transformation stored in this repository; its release asset is also SHA-256 pinned. Nix itself is installed from a version-specific official Nix release URL. `nix-portable` is version-pinned and enabled only where a digest is explicitly recorded.

## License

MIT
