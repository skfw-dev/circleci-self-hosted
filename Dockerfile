# syntax=docker/dockerfile:1

# CircleCI machine runner 3 in a container.
#
# The upstream image (Ubuntu 22.04, user "circleci", uid 1500) ships without
# git and without an SSH client, so the built-in `checkout` step cannot work on
# it as-is. The "runner" stage adds both. Jobs run INSIDE this container, so
# every tool a pipeline needs has to be installed here.

ARG RUNNER_IMAGE_TAG=machine-3
ARG DOCKER_CLI_IMAGE=docker:27-cli

FROM ${DOCKER_CLI_IMAGE} AS docker-cli

# ---------------------------------------------------------------------------
# runner: default target
# ---------------------------------------------------------------------------
FROM circleci/runner-agent:${RUNNER_IMAGE_TAG} AS runner

# Space-separated extra apt packages, e.g. "python3 build-essential jq".
ARG EXTRA_APT_PACKAGES=""

USER 0
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install --no-install-recommends -y \
      ca-certificates \
      curl \
      git \
      gzip \
      openssh-client \
      tar \
      unzip \
      ${EXTRA_APT_PACKAGES} \
 && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 docker/entrypoint.sh /usr/local/bin/runner-entrypoint

# 1500 is the upstream "circleci" user.
USER 1500
ENTRYPOINT ["/usr/local/bin/runner-entrypoint"]

# ---------------------------------------------------------------------------
# runner-dood: adds the Docker CLI for use with compose.dood.yaml
# (the host's Docker socket is mounted; no daemon runs in this container)
# ---------------------------------------------------------------------------
FROM runner AS runner-dood

COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins /usr/local/libexec/docker/cli-plugins
