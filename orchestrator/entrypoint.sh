#!/usr/bin/env bash
# Entrypoint for the autoresearch orchestrator ("brain").
#
# A headless Claude Code loop that drives bg-fomo's frozen autoresearch harness on
# the T4 cluster: it checks out the bg-ai agent branch, reads the FROZEN program.md,
# and then edits candidate.py -> commits -> creates a per-run ConfigMap + Job ->
# waits -> greps score.json -> keeps/discards, looping until the Deployment is scaled
# to 0. It never touches the eval, the data, or any other namespace (RBAC enforces
# this; see bg-infra rbac.yaml).
#
# Runs as the in-cluster `autoresearch-runner` ServiceAccount (in-cluster kubeconfig),
# so `kubectl` here is already scoped to Jobs/pods/logs/configmaps in `autoresearch`.
set -euo pipefail

# --- secrets (injected from the autoresearch-orchestrator-secrets Secret) ----------
: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set (orchestrator Secret)}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set (orchestrator Secret)}"
# --- config (from the Deployment env) ----------------------------------------------
: "${BG_AI_BRANCH:?BG_AI_BRANCH must be set (the agent branch to advance)}"
AUTORESEARCH_NAMESPACE="${AUTORESEARCH_NAMESPACE:-autoresearch}"
BG_AI_REPO="${BG_AI_REPO:-github.com/Biographica/bg-ai.git}"
WORKDIR="${WORKDIR:-/work}"

# 1. RBAC self-check (program.md setup step): confirm we can see our own quota and
#    cannot see another namespace. Fail fast if the boundary is wrong.
echo "[orchestrator] RBAC self-check in ns=${AUTORESEARCH_NAMESPACE}"
kubectl -n "${AUTORESEARCH_NAMESPACE}" get resourcequota

# 2. Check out the bg-ai agent branch (the brain holds the only git token in-cluster;
#    Job pods stay credential-less — candidate.py reaches them via ConfigMap).
mkdir -p "${WORKDIR}" && cd "${WORKDIR}"
if [ ! -d bg-ai ]; then
  git clone "https://x-access-token:${GITHUB_TOKEN}@${BG_AI_REPO}" bg-ai
fi
cd bg-ai
git fetch origin "${BG_AI_BRANCH}" && git checkout "${BG_AI_BRANCH}"
cd ml/bg-fomo

# 3. Hand the loop to headless Claude Code, driven by the FROZEN program.md.
#
# TODO(autoresearch): confirm the exact non-interactive invocation + turn/budget
# policy for a long-lived autonomous loop. `claude -p` runs a single pass; program.md
# says to loop "until manually stopped", so this likely needs an outer `while` here
# (re-invoking per keep/discard cycle) and/or a resumable session. Tool-permission
# scoping (`kubectl`, `git`, Edit on candidate.py only) must mirror program.md's
# "what you CAN/CANNOT do". The loop STOPS when the Deployment is scaled to 0
# (replicas:0) — the pod is terminated between cycles.
echo "[orchestrator] starting headless Claude Code loop on ${BG_AI_BRANCH}"
exec claude --print \
  --permission-mode acceptEdits \
  "$(cat program.md)"
