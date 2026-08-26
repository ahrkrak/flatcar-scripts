# Flatcar dev & build environment (macOS / Apple Silicon)

This directory contains the local development and build environment for this
downstream Flatcar fork.

- **Fork:** `ahrkrak/flatcar-scripts` (`origin`)
- **Upstream:** `flatcar/scripts` (`upstream`, push disabled)

## Why it is not just "run the SDK on your Mac"

Two hard constraints shape this setup:

1. **Case sensitivity.** The Flatcar SDK builds a Gentoo/portage tree, which
   requires a case-sensitive filesystem. This Mac's APFS root volume is
   case-insensitive, so the build tree cannot live under `/Users`.
2. **Bind-mount paths.** `run_sdk_container` bind-mounts `"$PWD"` into the SDK
   container, so the tree has to sit on a path the Docker *daemon* can see
   directly — not a macOS virtiofs share.

The solution: the build tree lives in a Docker named volume (ext4,
case-sensitive) inside the Docker Desktop VM. A small **dev shell** control
container mounts that volume at its real daemon-side path plus the Docker
socket, and launches the SDK container as a *sibling*. Paths therefore resolve
identically on both sides.

There is a third constraint worth knowing: Flatcar publishes the SDK container
for **amd64 only**. On Apple Silicon it runs under Docker Desktop's Rosetta
emulation. This works (verified), but expect builds to be substantially slower
than on a native x86_64 Linux host.

```
macOS                          Docker Desktop VM (linux/arm64)
─────                          ──────────────────────────────
~/projects/flatcar-scripts     flatcar-devshell (control, arm64)
  editing, git, PRs      ──▶     └─ docker.sock ──▶ flatcar-sdk-all:<ver>
  devenv/flatcar-dev                                (amd64 via Rosetta,
                                                     --privileged)
                               volume: flatcar-scripts-src (ext4)
                                 └─ /scripts   ← the build tree
```

## Two checkouts, on purpose

| | Mac clone (`~/projects/flatcar-scripts`) | Volume tree (`flatcar-scripts-src`) |
|---|---|---|
| Purpose | Editing, review, commits, pushes | Building |
| Filesystem | APFS, case-insensitive | ext4, case-sensitive |
| Talks to | GitHub | SDK container |

Edit on the Mac, then `flatcar-dev sync` to move your branch into the build
tree. Build artifacts stay in the volume and never touch your Mac's disk.

## Usage

```bash
./devenv/flatcar-dev up          # create/start the dev shell (idempotent)
./devenv/flatcar-dev status      # environment + git status on both sides
./devenv/flatcar-dev shell       # shell in the build tree, inside the VM
./devenv/flatcar-dev sdk         # interactive Flatcar SDK shell
./devenv/flatcar-dev sync        # push current Mac branch into the build tree
./devenv/flatcar-dev fix-sandbox # rebuild patched sandbox in the SDK container
./devenv/flatcar-dev fetch-upstream
./devenv/flatcar-dev down        # stop dev shell (build tree preserved)
./devenv/flatcar-dev destroy     # also delete the build tree volume
```

Running a build non-interactively:

```bash
./devenv/flatcar-dev run -- ./build_packages --board=amd64-usr
./devenv/flatcar-dev run -- ./build_image --board=amd64-usr prod oem_sysext
```

### Long builds: use `run`, not `sdk --`

`flatcar-dev run` wraps the command in `devenv/sdk-run.sh`, which executes it
*inside* the SDK container and writes the log there. Use it for anything that
takes more than a few minutes. It exists because of two sharp edges:

**1. `run_sdk_container -- ...` does not accept shell syntax.**
`sdk_lib/sdk_entry.sh` builds the command line by quoting every argument
individually:

```sh
for arg in "$@"; do echo -n "\"$arg\" " >>"$cmd"; done
```

so a pipeline like `./build_image ... | tee log` arrives as one quoted word and
bash reports `No such file or directory`. Only a command plus plain arguments
survive. Keeping the plumbing in a script file avoids the problem.

**2. A `docker exec` stream can drop without killing the build.**
It is a hijacked HTTP connection through Docker's API proxy. If the client goes
away — Docker Desktop revalidating itself, the laptop sleeping, a closed
terminal — the CLI exits **0** and you land back at a prompt, while the build
carries on inside the container. A host-side `| tee` is then truncated
mid-line, with no summary and no exit status. This has happened here: a
`build_packages` run appeared to "return to the command line" ~8 minutes before
it actually finished, successfully.

`sdk-run.sh` writes the log inside the container instead, so a disconnect
cannot lose it, and records the build's real exit code:

```
=== exit=0 at 2026-08-26T10:41:26-00:00 ===
```

Note that code is captured via `PIPESTATUS[0]`, not `tee`'s status — a plain
`cmd | tee log` pipeline always reports success regardless of how `cmd` fared.

Logs are named after the command (`build_image` → `image.log`) and land in the
tree root. Follow one live, or after reconnecting:

```bash
./devenv/flatcar-dev log image      # tail -f image.log
./devenv/flatcar-dev log packages
```

Both the copied runner and the logs are gitignored, so the build tree stays
clean.

If the terminal does drop, the build is still running. Check with:

```bash
docker exec -i -u sdk flatcar-sdk-all-4790.0.0_os-4790.0.0 \
    bash -lc 'ps -eo args | grep "[b]uild_"'
```

Do **not** start a second build in the meantime — concurrent runs will collide
over the same board root.

### Version pinning

`FLATCAR_SDK_VERSION` defaults to a tag that actually exists in
`ghcr.io/flatcar` (nightly SDK containers referenced by `main` are generally not
published). `FLATCAR_OS_VERSION` defaults to the same value — if the sourcetree
version is left at the nightly value from git, the SDK entrypoint tries to
regenerate board configs against a binhost that was never published and the run
aborts.

```bash
FLATCAR_SDK_VERSION=4790.0.0 ./devenv/flatcar-dev sdk
```

To see what is available:

```bash
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:flatcar/flatcar-sdk-all:pull&service=ghcr.io" \
  | sed -E 's/.*"token":"([^"]+)".*/\1/')
curl -s -H "Authorization: Bearer $TOKEN" \
  https://ghcr.io/v2/flatcar/flatcar-sdk-all/tags/list | jq -r '.tags[]' | sort -V | tail
```

## Carried patch: sandbox under Rosetta

The amd64 SDK container runs under Apple Rosetta on this machine. Rosetta lets
the `ptrace()` attach sequence succeed but cannot expose x86_64 registers:
`PTRACE_GETREGS` fails with `EIO` and never writes the caller's buffer.

`sys-apps/sandbox` only uses ptrace for **static** ELFs (it normally works via
`LD_PRELOAD`), and it does not check the return value of `trace_get_regs()`. It
therefore reads uninitialized memory and kills the build with:

```
libsandbox/trace/linux/x86_64.c:pers_is_32():36: failure (Input/output error):
unknown x86_64 (CS) personality
```

In practice this means **every Go package fails to build** (Go emits static
binaries) while ordinary C packages are unaffected.

We carry a downstream fix in
`sdk_container/src/third_party/coreos-overlay/sys-apps/sandbox/`. It adds a
cached probe to the x86_64 `_trace_possible()` hook: when the register file is
unreadable, tracing is reported as impossible and libsandbox falls back to its
existing "Unable to trace static ELF" path. `LD_PRELOAD` sandboxing is
untouched, so only static binaries lose sandbox coverage instead of the build
aborting.

Both the probe result and the resulting "Unable to trace static ELF" notice are
logged via `sb_debug_dyn()` rather than as QA warnings, because the condition is
a property of the environment and not something you can act on — left as
warnings it produced two lines per static exec, which across a full
`build_packages` is thousands of lines. **The degradation is therefore silent.**

Be aware that `SANDBOX_DEBUG=1` does *not* usefully surface them: it floods
portage's message pipe hard enough to abort the ebuild during `unpack`. That is
pre-existing upstream behaviour, not something this patch introduced — it
reproduces on packages that never execute a static ELF at all (verified with
`app-arch/xz-utils`). Treat this section as the documentation of record for the
fact that static binaries build unsandboxed on this host.

That package is the only one in `coreos-overlay` shadowing `portage-stable`
(which is an unmodified Gentoo mirror and must not be patched directly). When
sandbox is bumped upstream, re-copy the ebuild and refresh the patch — or drop
the package entirely if the fix is accepted upstream.

### Applying it

The SDK's sandbox lives in the **SDK container's** filesystem, not in the build
tree, so it must be rebuilt once per SDK container:

```bash
./devenv/flatcar-dev sdk          # create the SDK container (first time only)
./devenv/flatcar-dev fix-sandbox  # rebuild sandbox from coreos-overlay
```

Re-run `fix-sandbox` after anything that recreates the SDK container (a new
`FLATCAR_SDK_VERSION`, or `docker rm` of the container). It is idempotent and
verifies the patch is present in the installed `libsandbox.so`.

Note this removes the *blocker*, not the *slowness*: Go packages still compile
under emulation and a full `build_packages` takes many hours. A native x86_64
Linux host remains the practical answer for full builds.

## Staying current with upstream

```bash
./devenv/flatcar-dev fetch-upstream
git rebase upstream/main        # or merge, in the Mac clone
git push origin main
./devenv/flatcar-dev sync
```

## Resource notes

Full `build_packages` runs are long and disk-hungry, and slower still under
emulation. Docker Desktop is allocated 64 GiB of RAM on this machine; if you
move to another host, raise memory (and CPU count) in Docker Desktop →
Settings → Resources before attempting a full image build — the default
allocation gets builds SIGKILLed (exit 137). If full builds become a
bottleneck, the same tree and commands work unchanged on a native x86_64 Linux
host.
