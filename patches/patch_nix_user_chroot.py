#!/usr/bin/env python3
from pathlib import Path

path = Path("upstream/src/main.rs")
text = path.read_text()

def replace_once(old: str, new: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one match, found {count}: {old[:80]!r}")
    text = text.replace(old, new, 1)

replace_once(
    'const NONE: Option<&\'static [u8]> = None;\n',
    '''const NONE: Option<&'static [u8]> = None;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RootMethod {
    Pivot,
    Chroot,
}

impl RootMethod {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "pivot" => Some(Self::Pivot),
            "chroot" => Some(Self::Chroot),
            _ => None,
        }
    }
}
''',
)

replace_once(
    '    fn run_chroot(&self, cmd: &str, args: &[String], path_config: Option<PathConfig>) {\n',
    '''    fn run_chroot(
        &self,
        root_method: RootMethod,
        cmd: &str,
        args: &[String],
        path_config: Option<PathConfig>,
    ) {
''',
)

replace_once(
    '''        // chroot
        unistd::pivot_root(self.rootdir, &nix_mount).unwrap_or_else(|err| {
            panic!(
                "pivot_root({}, {}): {}",
                self.rootdir.display(),
                &nix_mount.display(),
                err
            )
        });

        // mount the store and hide the old root we fetch nixdir under the old root
        let nix_store = nix_root.join(self.nixdir);
        mount(
            Some(&nix_store),
            "/nix",
            Some("none"),
            MsFlags::MS_BIND | MsFlags::MS_REC,
            NONE,
        )
        .unwrap_or_else(|_| panic!("failed to bind mount {} to /nix", nix_store.display()));

        env::set_current_dir("/").expect("cannot change directory to /");
''',
    '''        match root_method {
            RootMethod::Pivot => {
                // Preserve the upstream root-switch path exactly for ordinary hosts.
                unistd::pivot_root(self.rootdir, &nix_mount).unwrap_or_else(|err| {
                    panic!(
                        "pivot_root({}, {}): {}",
                        self.rootdir.display(),
                        &nix_mount.display(),
                        err
                    )
                });

                // The old root is temporarily reachable below /nix after pivot_root,
                // so retain the upstream re-bind that hides it with the real store.
                let nix_store = nix_root.join(self.nixdir);
                mount(
                    Some(&nix_store),
                    "/nix",
                    Some("none"),
                    MsFlags::MS_BIND | MsFlags::MS_REC,
                    NONE,
                )
                .unwrap_or_else(|_| panic!("failed to bind mount {} to /nix", nix_store.display()));
            }
            RootMethod::Chroot => {
                // The physical store is already bind-mounted at <rootdir>/nix.
                // After chroot(rootdir), that same mount is directly visible as /nix.
                unistd::chroot(self.rootdir)
                    .unwrap_or_else(|err| panic!("chroot({}): {}", self.rootdir.display(), err));
            }
        }

        env::set_current_dir("/").expect("cannot change directory to /");
''',
)

replace_once(
    '''    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("Usage: {} <nixpath> <command>\\n", args[0]);
        process::exit(1);
    }

    let rootdir = mkdtemp::mkdtemp("nix-chroot.XXXXXX")
        .unwrap_or_else(|err| panic!("failed to create temporary directory: {err}"));

    let nixdir = fs::canonicalize(&args[1])
        .unwrap_or_else(|err| panic!("failed to resolve nix directory {}: {}", &args[1], err));
''',
    '''    let args: Vec<String> = env::args().collect();
    let (root_method, nixpath_idx, command_idx) =
        if args.get(1).map(String::as_str) == Some("--root-method") {
            if args.len() < 5 {
                eprintln!(
                    "Usage: {} [--root-method pivot|chroot] <nixpath> <command>\\n",
                    args[0]
                );
                process::exit(1);
            }

            let root_method = RootMethod::parse(&args[2]).unwrap_or_else(|| {
                eprintln!(
                    "invalid root method '{}': expected pivot or chroot",
                    args[2]
                );
                process::exit(2);
            });

            (root_method, 3, 4)
        } else {
            if args.len() < 3 {
                eprintln!(
                    "Usage: {} [--root-method pivot|chroot] <nixpath> <command>\\n",
                    args[0]
                );
                process::exit(1);
            }

            // No flag means the exact historical/upstream behavior.
            (RootMethod::Pivot, 1, 2)
        };

    let rootdir = mkdtemp::mkdtemp("nix-chroot.XXXXXX")
        .unwrap_or_else(|err| panic!("failed to create temporary directory: {err}"));

    let nixdir = fs::canonicalize(&args[nixpath_idx]).unwrap_or_else(|err| {
        panic!(
            "failed to resolve nix directory {}: {}",
            &args[nixpath_idx], err
        )
    });
''',
)

replace_once(
    '''        Ok(ForkResult::Child) => {
            RunChroot::new(&rootdir, &nixdir).run_chroot(&args[2], &args[3..], path_config)
        }
''',
    '''        Ok(ForkResult::Child) => {
            RunChroot::new(&rootdir, &nixdir).run_chroot(
                root_method,
                &args[command_idx],
                &args[command_idx + 1..],
                path_config,
            )
        }
''',
)

path.write_text(text)
