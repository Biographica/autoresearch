# RUNBOOK — standing up the FOMO autoresearch loop (v1)

Companion to `AUTORESEARCH_PLAN.md`. Ordered, checkable steps from zero → first unattended overnight run on the **T4 cluster** (`bg-kubernetes`, italynorth) — the v1 search target. A100 `bg-gpu-de` is scale-up only (Phase 9).

**Status (2026-10-06):** Phases 1–2 are up as two open **draft** PRs — plantbench **#60** (the benchmark-owned split) and bg-ai **#59** (the FOMO harness). Nothing on the cluster/S3/image has been executed yet; the rest is a checklist, not a record of done work.

**Owner legend:** `[H]` human (you/admin) · `[CI]` CI pipeline · `[AG]` the headless agent (only after setup). The agent never does `[H]`/`[CI]` steps — that separation is the safety model.

**PRs this runbook relates to:**
- **plantbench PR (`bg-ai` #60):** the benchmark‑owned split (`test_split_stratifications`) + tests — reviewed, merged, and published to repoforge FIRST; FOMO then bumps its `plantbench` pin to consume it.
- **PR-A (`bg-ai` #59):** frozen FOMO harness code (scorer + entrypoint + config + Dockerfile). No split artifact — the split lives in plantbench.
- **PR-B (`bg-infra`):** `autoresearch` namespace + ServiceAccount + RBAC + ResourceQuota (+ the data PVC) **+ the orchestrator `Deployment`** under Flux. (The orchestrator *image* is built from this `autoresearch` repo; only its deploy/permissions live in bg-infra.)

---

## Phase 0 — Decisions locked (pre-flight)
- [x] `[H]` v1 cluster = **T4 `bg-kubernetes` / italynorth** (confirmed). A100 is scale-up only.
- [x] `[H]` Primary metric = **Spearman-r on the `validation` split** (decided for v1; pending colleague review in the plantbench PR #60).
- [x] `[H]` v1 ships **without MLflow** (`score.json` + `results.tsv` only).
- [ ] `[H]` Create a **dedicated Entra identity** for the loop, *outside* `aks-bg-kubernetes-admins` (Q10). Record its client-id for PR-B.
  - Verify: the identity exists and is **not** a member of the AKS admin group.

## Phase 1 — Frozen harness code → open PR-A (`bg-ai`) ✅ done (PR #59, draft — not merged)
- [x] `[H]` Branch `bg-ai`: `git checkout -b feat/autoresearch-harness`.
- [x] `[H]` Add `ml/bg-fomo/src/fomo/models/candidate.py` — the single editable model (seed baseline = current best FOMO BHI arch). (Plan §2)
- [x] `[H]` Add `ml/bg-fomo/src/fomo/autoresearch/scorer.py` — a thin, pure extractor of the `validation` Spearman-r (+ secondary scalars) out of `plantbench`'s `evaluate()` result; stdlib-only, no model imports. (Plan §3-T2)
- [x] `[H]` Add `ml/bg-fomo/src/workflow/autoresearch_run.py` — fixed `--budget-seconds` via Lightning `Timer(timedelta(...))`, **no MLflow logger** in v1, writes `score.json` to stdout + `/out`. (Plan §3-T3)
- [x] `[H]` Add `ml/bg-fomo/src/workflow/configs/experiments/autoresearch_dream.yaml` — pins `benchmark_version: "2025-06-02_14-16-47"`, `split: {seed: 42, val_fraction: 0.2}`, `precision: 16-mixed` (T4), `budget_seconds: 600`. (Plan §3-T4)
- [x] `[H]` Add precision guard: assert-reject `bf16-mixed` when the detected GPU is a T4. (Plan §3-T5)
- [x] `[H]` Add `ml/bg-fomo/Dockerfile.autoresearch` — standard CUDA-12.4 PyTorch base (NOT the SageMaker/ECR base), `plantbench` pinned via `uv.lock`, `FORGE_API_KEY` as a BuildKit **secret**. (Plan §3-T6, Appendix)
- [x] `[H]` Add `ml/bg-fomo/program.md` — the agent instruction file. (Plan §9)
  - Verify PR-A: repo-quality (ruff/mypy/pre-commit) + bg-fomo unit-tests **green** on #59. Remaining before merge = the gated `plantbench` pin bump (Phase 2).

## Phase 2 — Benchmark-owned split (reviewed in the plantbench PR, then consumed by PR-A)
- [x] `[H]` No split producer to run: the split is **owned by the benchmark**. `plantbench`'s `test_split_stratifications(seed=42, val_fraction=0.2)` deterministically partitions DREAM `test` into `validation` + disjoint `locked_test` at runtime — no `make_autoresearch_split.py` / `split_manifest.parquet` / `SPLIT.md`. (Plan §3-T1)
- [x] `[H]` **Review gate:** the split method + params are up as the **plantbench PR (`bg-ai` #60)** (the `test_split_stratifications` impl + unit tests, CI green). → **request colleague review there** (the principle #2/#5 human sign-off on locked test + no leakage).
- [ ] `[H]` **Gate:** colleagues approve; merge PR #60 so plantbench publishes to repoforge.
- [ ] `[H]` Bump FOMO's `plantbench` pin to the published version (the `TODO(gated)` in `ml/bg-fomo/pyproject.toml`), then merge PR-A (#59).
  - Verify: `autoresearch_dream.yaml` carries `split: {seed, val_fraction}`; no `manifest_sha256`.

## Phase 3 — Build + lock the frozen image
- [ ] `[H/CI]` `az acr build`/`docker build` + push `biographicaregistry.azurecr.io/autoresearch-fomo:<tag>` (AcrPush — you/CI, never the agent).
- [ ] `[H]` Lock the tag immutable: `az acr repository update --name biographicaregistry --image autoresearch-fomo:<tag> --write-enabled false`.
  - Verify: `az acr repository show ... --query changeableAttributes.writeEnabled` → `false`; the agent identity has **no** AcrPush.

## Phase 4 — Mirror the data snapshot into Azure (italynorth)
- [ ] `[H]` One-time copy DREAM snapshot (~0.6 GB) from `s3://bg-data-prd/...` → Azure Blob/managed disk in **italynorth** (use the existing `bg-dagster-prod` AWS role; keyless Azure write). (Plan §5)
- [ ] `[H]` Lay out on the volume as `plantbench`'s loader/cache expects: the DREAM snapshot (`train`, `test`, `test_labels`) under `/data/dream_2025-06-02_14-16-47/`. `test_labels` **is** present — the benchmark derives `validation`/`locked_test` from it and `evaluate()` needs it to score `validation`.
  - Verify: file count/sizes match the snapshot. `locked_test` isolation is **behavioural** (the frozen entrypoint only scores `validation`; the human-only `locked_test` eval is a separate step), not data-withholding.

## Phase 5 — Cluster access control → open + merge PR-B (`bg-infra`)
- [x] `[H]` Branch `bg-infra` (`feat/autoresearch-namespace-rbac`, PR #307).
- [x] `[H]` Add the namespace infra under `clusters/prod-azure/namespaces/autoresearch/`: `serviceaccount.yaml` (SA `autoresearch-runner`, credential-less in v1), `rbac.yaml` (Role: `batch/jobs` CRUD + `pods,pods/log,pods/status` + `configmaps` + `resourcequotas` read; RoleBinding to the SA), `resourcequota.yaml` (`requests.nvidia.com/gpu: "1"`, cpu/mem/pods caps), the read-only data `PersistentVolumeClaim` (**PR #307**), and `deployment.yaml` — the orchestrator brain, `replicas: 0` until Phase 6 (**PR #313**, stacked on #307). (Plan §6/§7)
- [x] `[H]` Wire into Flux (`flux-infra-azure/autoresearch-kustomization.yaml` + the namespace `kustomization.yaml` resource list). (PR #307 + #313)
- [ ] `[H]` Review + merge PR #307 then #313; let Flux apply (or `flux reconcile`).
  - Verify: `kubectl -n autoresearch get sa,role,rolebinding,resourcequota,pvc` all present; the runner identity can create Jobs **only** in `autoresearch` (`kubectl auth can-i create jobs -n autoresearch --as=...` → yes; `--as=... -n dagster-cloud` → no).

## Phase 6 — Orchestrator (headless Claude Code)
- [ ] `[H]` Build the orchestrator image from **this `autoresearch` repo**'s `Dockerfile` (Claude Code + kubectl + git + `program.md`/loop entrypoint), pushed to ACR by a human/CI.
- [ ] `[H]` Start it via the **`orchestrator-deployment.yaml` in bg-infra** (Flux): CPU node, `karpenter.sh/do-not-disrupt`, bound to the `autoresearch-runner` Role — **not** cluster-admin. **Start = set `replicas: 1` in bg-infra and let Flux reconcile; stop = `replicas: 0`.** (Plan §6 → orchestrator)
- [ ] `[H]` Give it the frozen `job-template.yaml`, read access to the `bg-ai` branch, and `program.md`.
  - Verify: from the orchestrator, `kubectl -n autoresearch get resourcequota` works; `kubectl -n dagster-cloud get pods` is **denied**.

## Phase 7 — Noise-floor calibration (before any editing)
- [ ] `[H/AG]` Run the **baseline** candidate 10× (training seeds 0–9, fixed split seed 42) at `budget_seconds=600`; record μ₀, σ₀ of the `validation` Spearman-r. (Plan §4)
  - Verify: σ₀ computed and written into the keep/discard threshold; baseline μ₀ logged as run #0 in `results.tsv`.

## Phase 8 — Safety drill (do before leaving it unattended)
- [ ] `[H]` Kill-switch test (two independent levers): (a) GPU quota — `kubectl -n autoresearch patch resourcequota autoresearch-quota -p '{"spec":{"hard":{"requests.nvidia.com/gpu":"0"}}}'` → a new Job stays Pending/denied; restore to `"1"`. (b) Orchestrator on/off — set the `orchestrator-deployment` `replicas: 0` in bg-infra, let Flux reconcile → loop halts; restore to `1`.
- [ ] `[H]` Locked-test dry run: a human scores the baseline on the disjoint **`locked_test` stratum** — `benchmark.evaluate((sub, date), stratification=[strats["locked_test"]])` with the frozen `(seed=42, val_fraction=0.2)` — and confirms the result lands in the **human-only** `locked_test_results.tsv`, not in the agent's workdir.
  - Verify: both levers behave as designed; the loop only ever scores `validation`, and the `locked_test` output stays outside the agent's workdir (isolation is behavioural — the frozen entrypoint never scores `locked_test`).

## Phase 9 — First unattended v1 run
- [ ] `[AG]` Start the loop on `autoresearch/<tag>`: edit `candidate.py` → commit → render+create Job (capture generated name) → wait → read `score.json` → keep (advance) / discard (`git reset`) per the σ₀ rule → log `results.tsv` → repeat. (Plan §9)
  - Verify next morning: `results.tsv` has N runs; kept commits advance the branch; locked-test (checked by you per cadence) hasn't diverged from `val'`.

## Gate to widen → v2 (all must hold)
- [ ] Image tag immutable + agent has no AcrPush · [ ] split PR approved · [ ] σ₀ measured + gate wired · [ ] data mirrored (egress paid once) · [ ] namespace/RBAC/quota live · [ ] kill switch tested · [ ] locked-test cadence producing human-only reports.

## Phase 10 — A100 scale-up (later, `bg-gpu-de`)
- [ ] `[H]` Repeat Phases 3–5 for `bg-gpu-de` **via `kubectl` (no Flux there)**: `az aks get-credentials -g bg-gpu-de-rg -n bg-gpu-de`; apply namespace/SA/RBAC/RQ; mirror snapshot to **germanywestcentral**; build an `autoresearch-fomo-a100:<tag>` image with `precision: bf16-mixed`; re-measure σ₀/budget for A100.
- [ ] `[H]` Raise the `a100` pool `max_count` 1→4 only if running parallel A100 jobs.
  - Verify: a smoke Job lands on `workload=gpu-a100` with `nvidia.com/gpu:1` and reports an A100-80GB.
