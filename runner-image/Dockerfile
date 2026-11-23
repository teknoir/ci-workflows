# Runner image for the dev-host ARC scale sets (teknoir-ci, teknoir-land, teknoir-push).
# The upstream actions-runner image has no make, gcc or gh; land.sh needs gh, and most repos need make.
# Bump BASE together with the ARC values in platform-applications-gitops charts/ci-runners/arc/*.yaml.
ARG BASE=ghcr.io/actions/actions-runner:2.338.2@sha256:6d0b2d80d80f143f77dcb676e50920100bbb547e39e883454d57f45ab8c31300
FROM ${BASE}
ARG YQ_VERSION=v4.54.3
USER root
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg build-essential make xz-utils zstd; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    arch=$(dpkg --print-architecture); \
    curl -fsSL -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${arch}"; \
    chmod 0755 /usr/local/bin/yq; \
    rm -rf /var/lib/apt/lists/*; \
    make --version | head -1; gcc --version | head -1; gh --version | head -1; yq --version
USER runner
