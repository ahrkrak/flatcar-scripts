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
./devenv/flatcar-dev fetch-upstream
./devenv/flatcar-dev down        # stop dev shell (build tree preserved)
./devenv/flatcar-dev destroy     # also delete the build tree volume
```

Running a build non-interactively:

```bash
./devenv/flatcar-dev sdk -- ./build_packages --board=amd64-usr
./devenv/flatcar-dev sdk -- ./build_image --board=amd64-usr prod
```

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

## Staying current with upstream

```bash
./devenv/flatcar-dev fetch-upstream
git rebase upstream/main        # or merge, in the Mac clone
git push origin main
./devenv/flatcar-dev sync
```

## Resource notes

Full `build_packages` runs are long and disk-hungry, and slower still under
emulation. Docker Desktop is currently allocated ~7.7 GiB of RAM; raise it (and
CPU count) in Docker Desktop → Settings → Resources before attempting a full
image build. If full builds become a bottleneck, the same tree and commands work
unchanged on a native x86_64 Linux host.
