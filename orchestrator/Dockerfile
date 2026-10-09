# Orchestrator ("brain") image for the FOMO autoresearch loop: headless **opencode**
# driven by an Azure AI Foundry model, + kubectl + git. Built ONCE by a human/CI and
# pulled READ-ONLY from ACR; the agent identity has NO AcrPush, so the brain cannot
# rebuild itself (same discipline as the frozen eval image). It only CREATES k8s Jobs
# + per-run candidate ConfigMaps via the API — no docker-in-docker, no GPU.
#
# Why opencode (not Claude Code): the operator has only a personal Anthropic
# subscription, so the brain runs on a Foundry-hosted model via Azure credits.
# opencode's azure provider authenticates KEYLESS with an Entra bearer token (see
# plugin/azure-entra.ts) using the pod's Workload Identity — no API key anywhere.
#
# Build + push (human/CI). Context MUST be the repo root so the COPYs resolve:
#   az acr build -r biographicaregistry -t autoresearch-orchestrator:<tag> \
#       -f orchestrator/Dockerfile .
#
# Deployed via bg-infra (clusters/prod-azure/namespaces/autoresearch/deployment.yaml,
# Flux). On/off = that Deployment's replicas 1<->0. See AUTORESEARCH_PLAN.md §6.
FROM node:22-bookworm-slim

# git + kubectl + openssl/jq (the last two mint the GitHub App installation token in
# the credential helper). curl stays (the credential helper calls the GitHub API).
# Pin kubectl near the clusters' minor (keep within one minor of the API server).
ARG KUBECTL_VERSION=v1.31.4
# Pin opencode for a reproducible image. CONFIRM the tag with `npm view opencode-ai
# version` before building. NOTE: the ecosystem is migrating v1 (`opencode-ai`) -> v2
# (`@opencode/cli`); this image + config target the v1 line.
ARG OPENCODE_VERSION=1.18.3
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates openssl jq \
 && curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && rm -rf /var/lib/apt/lists/*

# Headless opencode (the brain), pinned.
RUN npm install -g opencode-ai@${OPENCODE_VERSION}

ENV HOME=/root
# Bake opencode's GLOBAL config, the Entra-auth plugin, and the plugin's npm deps.
# opencode runs `bun install` against this package.json at first start (one-time,
# needs egress; packages cache under ~/.cache/opencode). Keeping config + plugin in
# the global dir makes them independent of whatever repo workdir we clone into.
COPY orchestrator/opencode.json         /root/.config/opencode/opencode.json
COPY orchestrator/package.json          /root/.config/opencode/package.json
COPY orchestrator/plugin/azure-entra.ts /root/.config/opencode/plugin/azure-entra.ts

WORKDIR /app
COPY orchestrator/entrypoint.sh                   /app/entrypoint.sh
COPY orchestrator/github-app-credential-helper.sh /app/github-app-credential-helper.sh
RUN chmod +x /app/entrypoint.sh /app/github-app-credential-helper.sh

ENTRYPOINT ["/app/entrypoint.sh"]
