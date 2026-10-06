# autoresearch orchestrator (the "brain")

The headless **Claude Code** loop that drives the FOMO autoresearch harness. It is
the *driver*, not the eval: it edits the one editable file (`candidate.py`), launches
one experiment **Job** at a time on the T4 cluster, reads the Job's `score.json`, and
keeps/discards against the measured noise floor — looping until stopped.

| File | Role |
|---|---|
| `Dockerfile` | the brain image: Claude Code + kubectl + git. Built once by a human/CI, pulled read-only from ACR (the agent has **no AcrPush**). |
| `entrypoint.sh` | checks out the bg-ai agent branch, runs headless Claude Code against the **frozen** `ml/bg-fomo/program.md`. |

It only **creates** Jobs + per-run candidate ConfigMaps via the Kubernetes API — no
docker-in-docker, no GPU, not privileged. The mechanical boundary is RBAC, not trust
(see `bg-infra` `clusters/prod-azure/namespaces/autoresearch/rbac.yaml`).

## Where things live (and the on/off switch)

- **Image (what the brain is):** this repo — build from `orchestrator/Dockerfile`.
- **Deployment + SA/RBAC/quota/PVC (how it runs/is permissioned):** `bg-infra`
  (`clusters/prod-azure/namespaces/autoresearch/`, Flux-managed).
- **On/off:** the orchestrator `Deployment`'s **`replicas`** — set `1` in bg-infra to
  start, `0` to stop, and let Flux reconcile. The GPU `ResourceQuota` (set
  `requests.nvidia.com/gpu: "0"`) is the independent "halt in-flight work" kill switch.

## Build & deploy (human/CI — Phase 6)

```bash
az acr build -r biographicaregistry -t autoresearch-orchestrator:<tag> \
    -f orchestrator/Dockerfile .

# one-off, out of band (NOT in git): the brain's credentials
kubectl -n autoresearch create secret generic autoresearch-orchestrator-secrets \
    --from-literal=ANTHROPIC_API_KEY=... \
    --from-literal=GITHUB_TOKEN=...

# start: set the Deployment image tag + replicas:1 in bg-infra, let Flux reconcile.
```

## Status / TODO

Draft scaffold. The exact headless Claude Code invocation and long-lived-loop policy
(single pass vs. resumable session vs. outer `while`) are marked `TODO(autoresearch)`
in `entrypoint.sh`. Design + operational steps: `../AUTORESEARCH_PLAN.md` §6 and
`../RUNBOOK.md` Phases 6–9.
