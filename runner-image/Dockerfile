# Runner image for the dev-host ARC scale sets (teknoir-ci, teknoir-land, teknoir-push).
# The upstream actions-runner image has no make, gcc or gh; land.sh needs gh, and most repos need make.
# shellcheck, openssl, pip, PyYAML, helm, luajit and git-lfs are what the repos' old vpro CI images provided.
# Dependabot (weekly, .github/dependabot.yml) bumps the FROM line below; a merge
# to main builds ghcr.io/teknoir/ci-runner:sha-<8> (.github/workflows/runner-image.yml);
# Kargo's pin-ci-runner Stage in platform-applications-gitops pins it into
# charts/ci-runners/arc/*.yaml. GitHub stops sending jobs to runners more than
# 30 days older than a newer runner release, so a runner bump PR should land
# within days.
FROM ghcr.io/actions/actions-runner:2.338.2@sha256:6d0b2d80d80f143f77dcb676e50920100bbb547e39e883454d57f45ab8c31300
ARG YQ_VERSION=v4.54.3
ARG HELM_VERSION=v4.3.0
ENV PIP_BREAK_SYSTEM_PACKAGES=1
# Optional apt mirror (e.g. http://mirrors.edge.kernel.org/ubuntu) for when archive.ubuntu.com is slow; it stays in the image's apt sources.
ARG UBUNTU_MIRROR=
USER root
RUN set -eux; \
    if [ -n "${UBUNTU_MIRROR}" ]; then \
      sed -i -E "s#http://(archive|security)\.ubuntu\.com/ubuntu/?#${UBUNTU_MIRROR}/#g" /etc/apt/sources.list.d/ubuntu.sources; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg build-essential make xz-utils zstd \
      shellcheck openssl python3-pip python3-yaml luajit git-lfs; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    arch=$(dpkg --print-architecture); \
    curl -fsSL -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${arch}"; \
    chmod 0755 /usr/local/bin/yq; \
    curl -fsSL -o /tmp/helm.tgz "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz"; \
    curl -fsSL -o /tmp/helm.tgz.sha256 "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz.sha256sum"; \
    echo "$(cut -d' ' -f1 /tmp/helm.tgz.sha256)  /tmp/helm.tgz" | sha256sum -c -; \
    tar -xzf /tmp/helm.tgz -C /usr/local/bin --strip-components=1 "linux-${arch}/helm"; \
    rm -f /tmp/helm.tgz /tmp/helm.tgz.sha256; \
    rm -rf /var/lib/apt/lists/*; \
    make --version | head -1; gcc --version | head -1; gh --version | head -1; yq --version; helm version --short; shellcheck --version | head -2; openssl version; python3 -c 'import yaml; print(yaml.__version__)'; pip3 --version; luajit -v; git lfs version
USER runner
