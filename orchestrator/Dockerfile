# Orchestrator ("brain") image for the FOMO autoresearch loop: headless Claude Code
# + kubectl + git. Built ONCE by a human/CI and pulled READ-ONLY from ACR; the agent
# identity has NO AcrPush, so the brain cannot rebuild itself (same discipline as the
# frozen eval image). It only CREATES Kubernetes Jobs + per-run candidate ConfigMaps
# via the API — no docker-in-docker, no GPU.
#
# Build + push (human/CI):
#   az acr build -r biographicaregistry -t autoresearch-orchestrator:<tag> \
#       -f orchestrator/Dockerfile .
#
# Deployed via bg-infra (clusters/prod-azure/namespaces/autoresearch/deployment.yaml,
# Flux). On/off = that Deployment's replicas 1<->0. See AUTORESEARCH_PLAN.md §6 and
# RUNBOOK.md Phase 6.
FROM node:22-bookworm-slim

# git + kubectl (+ ca-certs for HTTPS clone). Pin kubectl near the clusters' minor
# (bg-kubernetes / bg-gpu-de) — keep within one minor of the API server.
ARG KUBECTL_VERSION=v1.31.4
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates \
 && curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && apt-get purge -y curl && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

# Headless Claude Code CLI (the "brain").
RUN npm install -g @anthropic-ai/claude-code

WORKDIR /app
COPY orchestrator/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
