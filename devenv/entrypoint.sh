#!/usr/bin/env bash
set -euo pipefail

TREE="${FLATCAR_TREE:-/var/lib/docker/volumes/flatcar-scripts-src/_data/scripts}"
PROXY_SOCK=/run/docker-sdk.sock

# The Docker Desktop socket is root:root 0660, so the unprivileged "sdk" user
# cannot talk to it directly. Rather than chown the host VM's socket, expose a
# group-readable proxy socket instead.
if [[ -S /var/run/docker.sock ]]; then
    rm -f "${PROXY_SOCK}"
    socat "UNIX-LISTEN:${PROXY_SOCK},fork,mode=0660,user=sdk,group=sdk" \
          UNIX-CONNECT:/var/run/docker.sock &
    for _ in $(seq 1 50); do
        [[ -S "${PROXY_SOCK}" ]] && break
        sleep 0.1
    done
fi

# The tree is cloned by tooling running as root; hand it to the build user once.
if [[ -d ${TREE} ]] && [[ "$(stat -c %u "${TREE}")" != "$(id -u sdk)" ]]; then
    echo "devenv: taking ownership of ${TREE} (first run)..." >&2
    chown -R sdk:sdk "$(dirname "${TREE}")"
fi

su sdk -c 'git config --global --add safe.directory "*"' >/dev/null 2>&1 || true

export DOCKER_HOST="unix://${PROXY_SOCK}"
cd "${TREE}" 2>/dev/null || cd /home/sdk

exec gosu sdk env \
    DOCKER_HOST="unix://${PROXY_SOCK}" \
    FLATCAR_TREE="${TREE}" \
    HOME=/home/sdk \
    PWD="$(pwd)" \
    "$@"
