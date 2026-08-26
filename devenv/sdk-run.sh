#!/bin/bash
#
# sdk-run.sh - run a long build command inside the SDK container so that the
# log and the exit status survive a client disconnect.
#
# Two problems this solves:
#
#  1. sdk_lib/sdk_entry.sh builds the command line by wrapping every argument
#     in its own double quotes:
#
#         for arg in "$@"; do echo -n "\"$arg\" " >>"$cmd"; done
#
#     so anything passed to 'run_sdk_container -- ...' is a command plus plain
#     arguments only. Pipes, ';' and redirection arrive as literal text and
#     bash then treats the whole string as a filename. Keeping the shell
#     plumbing inside a script file sidesteps that entirely.
#
#  2. A 'docker exec' stream is a hijacked HTTP connection. If the client goes
#     away (Docker Desktop revalidating itself, a laptop sleeping, a closed
#     terminal) the CLI exits 0 while the build carries on inside the
#     container. Anything piped to 'tee' on the host is then truncated with no
#     summary and no exit status. Writing the log inside the container means a
#     disconnect cannot lose it, and the final line always records the real
#     exit code of the build - not tee's.
#
# Usage (from the tree root, inside the SDK container):
#   ./sdk-run.sh <command> [args...]
#
# Normally invoked via 'flatcar-dev run -- <command> [args...]'.

set -uo pipefail

if [[ $# -lt 1 ]]; then
    echo "sdk-run.sh: no command given" >&2
    exit 2
fi

cd /mnt/host/source/src/scripts || exit 1

# Name the log after the command, so build_packages and build_image do not
# overwrite each other: ./build_image -> image.log
log_base="$(basename "$1")"
log_base="${log_base#build_}"
LOG="/mnt/host/source/src/scripts/${log_base}.log"

{
    echo "=== $* ==="
    echo "=== started $(date -Is) ==="
} > "${LOG}"

"$@" 2>&1 | tee -a "${LOG}"
rc=${PIPESTATUS[0]}

echo "=== exit=${rc} at $(date -Is) ===" >> "${LOG}"
exit "${rc}"
