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
# The frozen eval image tag the brain renders into each Job. Exported under BOTH
# names: program.md uses $FROZEN_IMAGE_TAG; the job-template comment still shows $TAG.
export FROZEN_IMAGE_TAG="${FROZEN_IMAGE_TAG:-}"
export TAG="${FROZEN_IMAGE_TAG}"
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

# 1b. Give in-cluster kubectl a NAMED context. Without this, `kubectl config
#     current-context` is empty and some kubectl paths fall back to localhost:8080 —
#     which confused the brain during the first shakedown. The projected SA token + CA
#     are the standard in-cluster paths.
if [ -n "${KUBERNETES_SERVICE_HOST:-}" ] && [ -z "$(kubectl config current-context 2>/dev/null)" ]; then
  SA_DIR=/var/run/secrets/kubernetes.io/serviceaccount
  kubectl config set-cluster incluster \
    --server="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT:-443}" \
    --certificate-authority="${SA_DIR}/ca.crt" >/dev/null 2>&1 || true
  kubectl config set-credentials incluster --token="$(cat "${SA_DIR}/token")" >/dev/null 2>&1 || true
  kubectl config set-context incluster --cluster=incluster --user=incluster \
    --namespace="${AUTORESEARCH_NAMESPACE}" >/dev/null 2>&1 || true
  kubectl config use-context incluster >/dev/null 2>&1 || true
  echo "[orchestrator] in-cluster kube context set (current-context=$(kubectl config current-context 2>/dev/null))"
fi

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
# --- loop governance (env-overridable from the Deployment) ------------------------
#   The first shakedown showed a FAILURE MODE: a session that declares itself blocked
#   exits in seconds, the loop restarts it 10s later, and each restart re-sends the
#   full context — ~421k tokens in 6 min making zero progress. So: exponentially back
#   off when sessions exit "fast" (likely stuck), cap total sessions, and stop when a
#   cumulative token budget is hit. A healthy session (which spends most of its time
#   WAITING on a 10–40 min GPU Job) resets the backoff.
MAX_SESSIONS="${MAX_SESSIONS:-0}"                     # 0 = unlimited
OPENCODE_TOKEN_BUDGET="${OPENCODE_TOKEN_BUDGET:-0}"   # 0 = no cap; else pause when cumulative tokens >= this
MIN_SESSION_SECONDS="${MIN_SESSION_SECONDS:-90}"      # shorter than this ⇒ treat as a stuck/fast exit
BACKOFF_BASE="${BACKOFF_BASE:-15}"
BACKOFF_MAX="${BACKOFF_MAX:-600}"
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-60}"           # token-watchdog poll period (s)

tokens_used() {  # fail-open cumulative tokens from opencode's local stats
  # `opencode stats` is a box table; scan each line's fields for the numeric token
  # (NOT $NF — that's the trailing box border) and sum Input+Output+Cache{Read,Write}.
  opencode stats 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk '
    /Input|Output|Cache Read|Cache Write/ {
      for (i=1;i<=NF;i++) if ($i ~ /^[0-9][0-9.]*[KMkm]?$/) {
        v=$i; m=1; if (v ~ /[Kk]/) m=1000; if (v ~ /[Mm]/) m=1000000;
        gsub(/[^0-9.]/,"",v); sum+=v*m } } END { printf "%d", sum }' || true
}

# Background watchdog: the between-session gate (top of the loop) only fires at session
# boundaries; this kills the model loop MID-session the instant cumulative tokens cross
# the budget, so even one long UNATTENDED session cannot overspend Foundry.
BUDGET_HIT_FLAG=/tmp/.autoresearch_budget_hit
rm -f "$BUDGET_HIT_FLAG"
token_watchdog() {
  [ "${OPENCODE_TOKEN_BUDGET}" -gt 0 ] || return 0
  while true; do
    sleep "${WATCHDOG_INTERVAL}"
    u="$(tokens_used)"
    if [ -n "$u" ] && [ "$u" -ge "${OPENCODE_TOKEN_BUDGET}" ]; then
      echo "[orchestrator][watchdog] token budget hit (${u} >= ${OPENCODE_TOKEN_BUDGET}) — killing opencode + pausing." >&2
      touch "$BUDGET_HIT_FLAG"; pkill -f opencode 2>/dev/null || true
      return 0
    fi
  done
}
token_watchdog & WATCHDOG_PID=$!

# Clean shutdown on scale-down (k8s SIGTERM) so the pod exits within its grace period
# instead of being force-killed.
cleanup() { echo "[orchestrator] signal received — shutting down"; kill "${WATCHDOG_PID}" 2>/dev/null || true; pkill -f opencode 2>/dev/null || true; exit 0; }
trap cleanup TERM INT

echo "[orchestrator] starting headless opencode loop on ${BG_AI_BRANCH} (model ${OPENCODE_MODEL})"
echo "[orchestrator] governance: MAX_SESSIONS=${MAX_SESSIONS} OPENCODE_TOKEN_BUDGET=${OPENCODE_TOKEN_BUDGET} MIN_SESSION_SECONDS=${MIN_SESSION_SECONDS}"
session=0
backoff="${BACKOFF_BASE}"
while true; do
  if [ -f "$BUDGET_HIT_FLAG" ]; then
    echo "[orchestrator] token budget hit (watchdog) — loop paused. Scale the Deployment 0→1 to reset." >&2
    sleep infinity
  fi
  if [ "${OPENCODE_TOKEN_BUDGET}" -gt 0 ]; then
    used="$(tokens_used)"
    if [ -n "${used}" ] && [ "${used}" -ge "${OPENCODE_TOKEN_BUDGET}" ]; then
      echo "[orchestrator] TOKEN BUDGET reached (${used} >= ${OPENCODE_TOKEN_BUDGET}); pausing. Scale the Deployment 0→1 to reset." >&2
      sleep infinity
    fi
  fi
  session=$((session + 1))
  if [ "${MAX_SESSIONS}" -gt 0 ] && [ "${session}" -gt "${MAX_SESSIONS}" ]; then
    echo "[orchestrator] MAX_SESSIONS (${MAX_SESSIONS}) reached; pausing. Scale the Deployment 0→1 to reset." >&2
    sleep infinity
  fi

  echo "[orchestrator] === opencode session ${session} (cumulative≈$(tokens_used) tokens) ==="
  start="$(date +%s)"
  opencode run --auto --model "${OPENCODE_MODEL}" "$(cat program.md)" \
    || echo "[orchestrator] opencode run exited $?"
  elapsed=$(( $(date +%s) - start ))

  if [ "${elapsed}" -lt "${MIN_SESSION_SECONDS}" ]; then
    echo "[orchestrator] session ${session} exited fast (${elapsed}s < ${MIN_SESSION_SECONDS}s) — backing off ${backoff}s" >&2
    sleep "${backoff}"
    backoff=$(( backoff * 2 ))
    if [ "${backoff}" -gt "${BACKOFF_MAX}" ]; then backoff="${BACKOFF_MAX}"; fi
  else
    backoff="${BACKOFF_BASE}"   # a healthy (long) session resets the backoff
    sleep 5
  fi
done
