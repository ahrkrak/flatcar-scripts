# Control ("dev shell") container for building Flatcar on macOS.
#
# This container is NOT the Flatcar SDK. It is a thin Linux-side control plane
# that lives inside the Docker Desktop VM, holds the build tree on a
# case-sensitive ext4 volume, and launches the real SDK container as a sibling
# via the mounted Docker socket.
FROM debian:bookworm-slim

ARG SDK_UID=1000
ARG SDK_GID=1000

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash ca-certificates curl git gnupg jq less openssh-client \
        procps socat sudo tar xz-utils zstd gosu \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g "${SDK_GID}" sdk \
    && useradd -m -u "${SDK_UID}" -g "${SDK_GID}" -s /bin/bash sdk \
    && echo "sdk ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sdk

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash", "-l"]
