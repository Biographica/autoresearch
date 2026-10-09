# autoresearch orchestrator (the "brain")

The headless **opencode** loop that drives the FOMO autoresearch harness. It is the
*driver*, not the eval: it edits the one editable file (`candidate.py`), launches one
experiment **Job** at a time on the T4 cluster, reads the Job's `score.json`, and
keeps/discards against the measured noise floor — looping until stopped.

It runs **opencode** (not Claude Code) driven by an **Azure AI Foundry** model,
because the operator has only a personal Anthropic subscription — so the brain runs
on Azure credits. Nothing about the loop is Claude-specific; the eval image and
`program.md` are model-agnostic.

| File | Role |
|---|---|
| `Dockerfile` | the brain image: opencode + kubectl + git (+ openssl/jq for the GitHub-App token). Built once by a human/CI, pulled read-only from ACR (the agent has **no AcrPush**). |
| `opencode.json` | opencode config: the `azure` provider (`@ai-sdk/azure`), model `azure/brain`, and the lockdown permission map (edit only `candidate.py`; bash only `git`/`kubectl`; everything else denied). |
| `plugin/azure-entra.ts` | opencode plugin that makes the azure provider authenticate **keyless** via Entra Workload Identity (`DefaultAzureCredential` → `Authorization: Bearer <AAD token>`). No API key is stored. |
| `package.json` | declares the plugin's npm dep (`@azure/identity`); opencode `bun install`s it at first start. |
| `github-app-credential-helper.sh` | git credential helper that mints + caches short-lived **GitHub App installation tokens** on demand, so the loop never holds a long-lived PAT. |
| `entrypoint.sh` | preflight + GitHub-App git auth + checks out the bg-ai agent branch + runs the headless opencode loop against the **frozen** `ml/bg-fomo/program.md`. |

It only **creates** Jobs + per-run candidate ConfigMaps via the Kubernetes API — no
docker-in-docker, no GPU, not privileged. The mechanical boundary is RBAC + the
frozen image, not trust (see `bg-infra` `.../autoresearch/rbac.yaml`).

## Authentication (no long-lived secrets beyond the GitHub App key)

- **Azure model — keyless.** The pod's `autoresearch-runner` SA is federated to a
  user-assigned managed identity (Terraform: `bg-infra/terraform/azure/autoresearch-foundry.tf`)
  with **Cognitive Services OpenAI User** on the Foundry account. The AKS
  workload-identity webhook injects `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` /
  `AZURE_FEDERATED_TOKEN_FILE`; the `azure-entra` plugin turns those into a bearer
  token. Requires the SA annotation `azure.workload.identity/client-id` (= the TF
  output) and the pod label `azure.workload.identity/use: "true"`.
- **GitHub — short-lived.** A GitHub App installed on `bg-ai` (Contents: R&W). The
  Secret holds `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, and the private-key
  `.pem` (mounted at `GITHUB_APP_PRIVATE_KEY_PATH`). The credential helper mints a
  1-hour installation token per git operation (cached), so no PAT is stored.

## Where things live (and the on/off switch)

- **Image (what the brain is):** this repo — build from `orchestrator/Dockerfile`.
- **Deployment + SA/RBAC/quota/PVC (how it runs/is permissioned):** `bg-infra`
  (`clusters/prod-azure/namespaces/autoresearch/`, Flux-managed).
- **Foundry resource + workload identity:** `bg-infra/terraform/azure/autoresearch-foundry.tf`.
- **On/off:** the orchestrator `Deployment`'s **`replicas`** — set `1` in bg-infra to
  start, `0` to stop, and let Flux reconcile. The GPU `ResourceQuota` (set
  `requests.nvidia.com/gpu: "0"`) is the independent "halt in-flight work" kill switch.

## Build & deploy (human/CI — Phase 6)

```bash
# context = repo root so the COPYs resolve
az acr build -r biographicaregistry -t autoresearch-orchestrator:<tag> \
    -f orchestrator/Dockerfile .

# one-off, out of band (NOT in git): the brain's credentials. Azure model access is
# keyless (workload identity) — the Secret only carries the GitHub App creds.
kubectl -n autoresearch create secret generic autoresearch-orchestrator-secrets \
    --from-literal=GITHUB_APP_ID=... \
    --from-literal=GITHUB_APP_INSTALLATION_ID=... \
    --from-file=private-key.pem=/path/to/app-private-key.pem

# Deployment env (bg-infra deployment.yaml): BG_AI_BRANCH, AZURE_OPENAI_RESOURCE
# (Foundry custom subdomain), AZURE_OPENAI_DEPLOYMENT (model deployment name), the
# pinned image tag + the workload-identity SA annotation/pod label. Then replicas:1.
```

## Deployment env contract

| Env | Source | Purpose |
|---|---|---|
| `BG_AI_BRANCH` | Deployment | the bg-ai branch the loop advances (one brain per branch) |
| `AZURE_OPENAI_RESOURCE` | Deployment (TF output) | Foundry custom subdomain → `https://<it>.openai.azure.com/` |
| `AZURE_OPENAI_DEPLOYMENT` | Deployment (TF) | the model deployment name opencode targets |
| `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID` | Secret | mint installation tokens |
| `GITHUB_APP_PRIVATE_KEY_PATH` | Secret (file) | default `/secrets/github-app/private-key.pem` |
| `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_FEDERATED_TOKEN_FILE` | injected by AKS | workload-identity (keyless Azure auth) |

## Status / TODO

- `OPENCODE_VERSION` is pinned in the Dockerfile — confirm the exact tag (`npm view
  opencode-ai version`) and v1-vs-v2 before the production build.
- First container start runs a one-time `bun install` for the plugin dep (needs
  egress). For a hermetic image, pre-warm it at build time.
- The plugin-dir name (`plugin/` vs `plugins/`) and whether edit globs are
  project-root- or cwd-relative should be confirmed against the pinned opencode build
  with a smoke run. Design + operational steps: `../AUTORESEARCH_PLAN.md` §6, `../RUNBOOK.md` Phases 6–9.
