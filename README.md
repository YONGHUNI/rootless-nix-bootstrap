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

The preferred backend is [`nix-user-chroot`](https://github.com/nix-community/nix-user-chroot), which requires unprivileged user namespaces. `nix-portable` is available only as an explicit fallback because its PRoot path can add significant overhead and has weaker host integration.

## Install

```bash
git clone https://github.com/YONGHUNI/rootless-nix-bootstrap.git
cd rootless-nix-bootstrap
./bootstrap.sh
```

If `~/.local/bin` is not already on `PATH`, bootstrap adds one small managed block to `~/.bashrc`. It does not automatically enter a Nix shell at login.

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

Automatic mode chooses `nix-user-chroot` only when an unprivileged user namespace probe succeeds:

```bash
./bootstrap.sh
```

If the host blocks user namespaces, bootstrap stops rather than silently switching to a slower runtime. The optional fallback is explicit:

```bash
./bootstrap.sh --backend portable
```

The current portable fallback is experimental. Its released bundle is older than the preferred backend and PRoot can impose substantial overhead. aarch64 portable fallback is disabled until an asset digest is pinned; aarch64 `nix-user-chroot` is fully supported.

## GPU hosts

When `nvidia-smi` is present, the `nix-user-chroot` backend links host `libcuda.so.1` (and `libnvidia-ml.so.1` when available) into the driver-library bridge expected by Nix software at `/run/opengl-driver/lib`.

The bootstrap does **not** install CUDA Toolkit, cuDNN, JAX, PyTorch, or other research dependencies. Those belong in the project flake/Pixi environment. The NVIDIA kernel driver remains a host responsibility.

## Slurm / HPC

On clusters where the home or project filesystem is shared, the physical Nix store can be shared as well. Each compute-node invocation creates its own rootless namespace when the `nix` wrapper runs; the store contents do not need to be reinstalled per node. If the selected store is on NFS, bootstrap detects that case and sets `use-sqlite-wal = false`, as recommended for writable Nix stores on NFS. Filesystem/site policies still matter, especially under concurrent jobs.

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

The uninstaller removes only the PATH block managed by this project and files recorded as bootstrap-managed.

## Security / downloads

The preferred `nix-user-chroot` release is version-pinned and verified against the SHA-256 digest published with its GitHub release. Nix itself is installed from a version-specific official Nix release URL. `nix-portable` is version-pinned and enabled only where a digest is explicitly recorded.

## License

MIT
