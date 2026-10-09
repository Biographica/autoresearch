#!/usr/bin/env bash
# Entrypoint for the autoresearch orchestrator ("brain").
#
# A headless **opencode** loop that drives bg-fomo's frozen autoresearch harness on
# the T4 cluster: it checks out the bg-ai agent branch, reads the FROZEN program.md,
# then edits ONLY candidate.py -> commits -> creates a per-run ConfigMap + Job ->
# waits -> reads score.json -> keeps/discards, looping until the Deployment is scaled
# to 0. It never touches the eval, the data, or any other namespace (RBAC + the
# frozen image enforce this; opencode.json also scopes edits to candidate.py and bash
# to git/kubectl).
#
# AUTH (no long-lived secrets beyond the GitHub App private key):
#   - Azure model: KEYLESS via Entra Workload Identity (the azure-entra opencode
#     plugin + DefaultAzureCredential). Needs the SA annotation
#     azure.workload.identity/client-id + the pod label
#     azure.workload.identity/use=true (set in bg-infra, from the Terraform output).
#   - GitHub: short-lived App installation tokens minted on demand by the git
#     credential helper (/app/github-app-credential-helper.sh).
set -euo pipefail

# --- required config (Deployment env) ---------------------------------------------
: "${BG_AI_BRANCH:?BG_AI_BRANCH must be set (the agent branch to advance)}"
: "${AZURE_OPENAI_RESOURCE:?AZURE_OPENAI_RESOURCE must be set (Foundry custom subdomain; TF output)}"
: "${AZURE_OPENAI_DEPLOYMENT:?AZURE_OPENAI_DEPLOYMENT must be set (model deployment name; TF)}"
: "${GITHUB_APP_ID:?GITHUB_APP_ID must be set (orchestrator Secret)}"
: "${GITHUB_APP_INSTALLATION_ID:?GITHUB_APP_INSTALLATION_ID must be set (orchestrator Secret)}"
# --- Workload Identity env (injected by the AKS webhook) --------------------------
: "${AZURE_FEDERATED_TOKEN_FILE:?Workload Identity env missing — is the SA annotated with azure.workload.identity/client-id and the pod labeled azure.workload.identity/use=true?}"
# --- optional config --------------------------------------------------------------
export GITHUB_APP_PRIVATE_KEY_PATH="${GITHUB_APP_PRIVATE_KEY_PATH:-/secrets/github-app/private-key.pem}"
export GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID
AUTORESEARCH_NAMESPACE="${AUTORESEARCH_NAMESPACE:-autoresearch}"
BG_AI_REPO="${BG_AI_REPO:-github.com/Biographica/bg-ai.git}"
WORKDIR="${WORKDIR:-/work}"
OPENCODE_MODEL="${OPENCODE_MODEL:-azure/brain}"

echo "[orchestrator] preflight: model=${OPENCODE_MODEL} resource=${AZURE_OPENAI_RESOURCE} deployment=${AZURE_OPENAI_DEPLOYMENT}"
[ -r "$GITHUB_APP_PRIVATE_KEY_PATH" ] \
  || { echo "ERROR: GitHub App private key not readable at $GITHUB_APP_PRIVATE_KEY_PATH" >&2; exit 1; }

# 1. RBAC self-check: we can see our own quota (and, by RBAC, cannot see another ns).
echo "[orchestrator] RBAC self-check in ns=${AUTORESEARCH_NAMESPACE}"
kubectl -n "${AUTORESEARCH_NAMESPACE}" get resourcequota

# 2. git auth via the GitHub App credential helper (mints + caches 1h installation
#    tokens on demand, so a multi-hour loop never holds a long-lived git token).
git config --global credential.useHttpPath false
git config --global "credential.https://github.com.helper" "/app/github-app-credential-helper.sh"

# 3. Check out the bg-ai agent branch (candidate.py reaches Job pods via ConfigMap;
#    the Job pods themselves stay credential-less).
mkdir -p "${WORKDIR}" && cd "${WORKDIR}"
if [ ! -d bg-ai ]; then
  git clone "https://${BG_AI_REPO}" bg-ai
fi
cd bg-ai
git fetch origin "${BG_AI_BRANCH}"
git checkout "${BG_AI_BRANCH}"
git config user.email "autoresearch-brain@biographica.bio"
git config user.name  "autoresearch brain"
cd ml/bg-fomo

# 4. Hand the loop to headless opencode, driven by the FROZEN program.md.
#    Each `opencode run` is ONE bounded agentic session (many edits/Jobs); the outer
#    loop restarts it for a fresh session. Cross-run memory lives in results.tsv /
#    research_notes.md (per program.md), NOT the LLM context — bounded + crash-robust
#    (a hung/poisoned session loses only one iteration). The loop ends when the
#    Deployment is scaled to 0 (the pod is terminated between iterations).
#    `--auto` + the allow/deny-only permission map in opencode.json => zero prompts,
#    so a non-TTY run never blocks.
echo "[orchestrator] starting headless opencode loop on ${BG_AI_BRANCH} (model ${OPENCODE_MODEL})"
while true; do
  opencode run --auto --model "${OPENCODE_MODEL}" "$(cat program.md)" \
    || echo "[orchestrator] opencode run exited $? — restarting after backoff"
  sleep 10
done
