# RUNBOOK — standing up the FOMO autoresearch loop (v1)

Companion to `AUTORESEARCH_PLAN.md`. Ordered, checkable steps from zero → first unattended overnight run on the **T4 cluster** (`bg-kubernetes`, italynorth) — the v1 search target. A100 `bg-gpu-de` is scale-up only (Phase 10).

**Two tracks (Plan §10/§13).** **v1 (Phases 0–9)** runs the current FOMO-coupled harness **once** — a single overnight campaign with the goal of **beating the baseline validation Spearman‑r by ≥ 5 %**. We do *not* refactor it. **v2 (the proper PR)** relocates everything into a standalone, model-agnostic **`bg-autoresearch`** package that onboards any model / statistical pipeline through a published interface — see the new **Track v2** section after the v2 gate.

**Status (2026-10-07):** plantbench **#60** reworked to the **train‑based** split (`train_validation_split` + `score_validation`) — `a5c0aacd` is pushed and **`plantbench 1.41.0rc1` is live on repoforge** (`build-and-publish` ✓; the only red check is the by‑design pre‑release merge‑guard). Two further #60 commits are staged (unpushed): a `score_validation` error‑hardening fix + a bump to **`1.41.0rc2`** — the next push republishes the package with the fix. bg-ai **#59** (the FOMO harness) is rewired to call the new API. bg-infra **#307 is merged** and **Flux is bootstrapped** on italynorth `bg-kubernetes` (namespace/SA/RBAC/quota + data PVC reconciling); the orchestrator Deployment is stacked in **#313** (`replicas: 0`, unmerged). No cluster‑GPU/S3/image step has run yet; the rest is a checklist, not a record of done work.

**Owner legend:** `[H]` human (you/admin) · `[CI]` CI pipeline · `[AG]` the headless agent (only after setup). The agent never does `[H]`/`[CI]` steps — that separation is the safety model.

**PRs this runbook relates to:**
- **plantbench PR (`bg-ai` #60):** the benchmark‑owned **train‑based** split (`train_validation_split` + `score_validation`) + tests — published to repoforge FIRST (`1.41.0rc1` live; the staged error‑hardening republishes as `1.41.0rc2`); FOMO then pins its `plantbench` dep to `==1.41.0rc2` and relocks.
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
- [x] `[H]` Add `ml/bg-fomo/src/fomo/autoresearch/scorer.py` — a thin, pure extractor of the `validation` Spearman-r (+ secondary scalars) out of `plantbench`'s `score_validation()` result (keys `validation.<Metric>.axis<n>`); stdlib-only, no model imports. (Plan §3-T2)
- [x] `[H]` Add `ml/bg-fomo/src/workflow/autoresearch_run.py` — fixed `--budget-seconds` via Lightning `Timer(timedelta(...))`, **no MLflow logger** in v1, writes `score.json` to stdout + `/out`. (Plan §3-T3)
- [x] `[H]` Add `ml/bg-fomo/src/workflow/configs/experiments/autoresearch_dream.yaml` — pins `benchmark_version: "2025-06-02_14-16-47"`, `split: {seed: 42, val_fraction: 0.2}`, `precision: 16-mixed` (T4), `budget_seconds: 600`. (Plan §3-T4)
- [x] `[H]` Add precision guard: assert-reject `bf16-mixed` when the detected GPU is a T4. (Plan §3-T5)
- [x] `[H]` Add `ml/bg-fomo/Dockerfile.autoresearch` — standard CUDA-12.4 PyTorch base (NOT the SageMaker/ECR base), `plantbench` pinned via `uv.lock`, `FORGE_API_KEY` as a BuildKit **secret**. (Plan §3-T6, Appendix)
- [x] `[H]` Add `ml/bg-fomo/program.md` — the agent instruction file. (Plan §9)
  - Verify PR-A: repo-quality (ruff/mypy/pre-commit) + bg-fomo unit-tests **green** on #59. Remaining before merge = the gated `plantbench` pin bump (Phase 2).

## Phase 2 — Benchmark-owned split (reviewed in the plantbench PR, then consumed by PR-A)
- [x] `[H]` No split producer to run: the split is **owned by the benchmark**. `plantbench`'s `train_validation_split(seed=42, val_fraction=0.2)` deterministically carves a `validation` subset out of DREAM's **`train`** pairs (leaving a disjoint `train` remainder) at runtime, and `score_validation()` scores it against the train labels — no `make_autoresearch_split.py` / `split_manifest.parquet` / `SPLIT.md`. (Plan §3-T1)
- [x] `[H]` **Review gate:** the split method + params are the **plantbench PR (`bg-ai` #60)** (the `train_validation_split` + `score_validation` impl + unit tests — 17 split + 22 sharik pass). → **request Paride's review** of the train‑based split (the principle #2/#5 human sign-off on locked test + no leakage).
- [x] `[H]` **Gate (partly done):** `a5c0aacd` is pushed and CI's `build-and-publish` published **plantbench 1.41.0rc1** to repoforge (the pre‑release path publishes even without merge; the `ensure-package-version-bump` merge‑guard stays red by design until a stable merge — ignore for v1). Staged on top: the `score_validation` error‑hardening + a bump to **1.41.0rc2** — push #60 again to republish as rc2 (with the fix).
- [ ] `[H]` Pin FOMO's `plantbench` to `==1.41.0rc2` (the `TODO(gated)` in `ml/bg-fomo/pyproject.toml`; `>=` won't pick a pre‑release), `uv lock`, then commit #59. (v1 runs off the #59 branch baked into the image — it need not merge to bg-ai master.)
  - Verify: `autoresearch_dream.yaml` carries `split: {seed, val_fraction}`; no `manifest_sha256`.

## Phase 3 — Build + lock the frozen image
- [ ] `[H/CI]` `az acr build`/`docker build` + push `biographicaregistry.azurecr.io/autoresearch-fomo:<tag>` (AcrPush — you/CI, never the agent).
- [ ] `[H]` Lock the tag immutable: `az acr repository update --name biographicaregistry --image autoresearch-fomo:<tag> --write-enabled false`.
  - Verify: `az acr repository show ... --query changeableAttributes.writeEnabled` → `false`; the agent identity has **no** AcrPush.

## Phase 4 — Mirror the data snapshot into Azure (italynorth)
- [ ] `[H]` One-time copy DREAM snapshot (~0.6 GB) from `s3://bg-data-prd/...` → Azure Blob/managed disk in **italynorth** (use the existing `bg-dagster-prod` AWS role; keyless Azure write). (Plan §5)
- [ ] `[H]` Lay out on the volume as `plantbench`'s loader/cache expects: the DREAM snapshot (`train`, `test`, `test_labels`) under `/data/dream_2025-06-02_14-16-47/`. The label table (`test_labels`) covers the train pairs too, so `score_validation` reads the `validation` labels from it; the `test` inputs are needed only for the human-only locked-test `evaluate()`.
  - Verify: file count/sizes match the snapshot. Test-set isolation is **behavioural** (the frozen entrypoint only ever calls `train_validation_split` + `score_validation`, never touching the `test` pairs; the human-only whole-test `evaluate()` is a separate step).

## Phase 5 — Cluster access control → open + merge PR-B (`bg-infra`)
- [x] `[H]` Branch `bg-infra` (`feat/autoresearch-namespace-rbac`, PR #307).
- [x] `[H]` Add the namespace infra under `clusters/prod-azure/namespaces/autoresearch/`: `serviceaccount.yaml` (SA `autoresearch-runner`, credential-less in v1), `rbac.yaml` (Role: `batch/jobs` CRUD + `pods,pods/log,pods/status` + `configmaps` + `resourcequotas` read; RoleBinding to the SA), `resourcequota.yaml` (`requests.nvidia.com/gpu: "1"`, cpu/mem/pods caps), the read-only data `PersistentVolumeClaim` (**PR #307**), and `deployment.yaml` — the orchestrator brain, `replicas: 0` until Phase 6 (**PR #313**, stacked on #307). (Plan §6/§7)
- [x] `[H]` Wire into Flux (`flux-infra-azure/autoresearch-kustomization.yaml` + the namespace `kustomization.yaml` resource list). (PR #307 + #313)
- [x] `[H]` PR #307 **merged** + Flux **bootstrapped** on italynorth (`prod-azure-autoresearch` Kustomization live; namespace/SA/RBAC/quota + data PVC reconciling — the PVC stays Pending until a Job mounts it).
- [ ] `[H]` Review + merge **#313** (orchestrator Deployment, `replicas: 0`); let Flux apply (or `flux reconcile`).
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
- [ ] `[H]` Locked-test dry run: a human builds a submission from the baseline and scores the **whole official `test` set** the normal way — `benchmark.submit(preds, name)` then `benchmark.evaluate((name, date))` — and confirms the result lands in the **human-only** `locked_test_results.tsv`, not in the agent's workdir.
  - Verify: both levers behave as designed; the loop only ever scores the train-derived `validation` subset, and the locked-test output stays outside the agent's workdir (isolation is behavioural — the frozen entrypoint never touches the `test` set).

## Phase 9 — First unattended v1 run (the single campaign)
- [ ] `[AG]` Start the loop on `autoresearch/<tag>`: edit `candidate.py` → commit → render+create Job (capture generated name) → wait → read `score.json` → keep (advance) / discard (`git reset`) per the σ₀ rule → log `results.tsv` → repeat. (Plan §9)
- [ ] `[H]` **Campaign success bar: validation Spearman‑r ≥ 1.05 × baseline μ₀** (a ≥ 5 % relative gain; Plan §4). Reaching it — or exhausting the night — *ends v1*. The next step is the Track v2 refactor below, **not** another v1 campaign on the throwaway harness.
  - Verify next morning: `results.tsv` has N runs; kept commits advance the branch; the best `val'` vs μ₀ is recorded against the +5 % bar; locked-test (checked by you per cadence) hasn't diverged from `val'`.

## Gate to widen → v2 (all must hold)
- [ ] Image tag immutable + agent has no AcrPush · [ ] split PR approved · [ ] σ₀ measured + gate wired · [ ] data mirrored (egress paid once) · [ ] namespace/RBAC/quota live · [ ] kill switch tested · [ ] locked-test cadence producing human-only reports · [ ] **v1 campaign produced its number** (hit — or honestly missed — the +5 % bar).

## Track v2 — `bg-autoresearch` (the proper, model-agnostic PR)
After the v1 campaign, **do not grow the in-`bg-fomo` harness.** Open a clean PR that relocates it into a standalone `bg-autoresearch` package (Plan §13). The onboarding interface for any new model / statistical pipeline is just: *(1) be scored by the same `bg-ai/libs/plantbench` metrics (submit an `AnnData` its `validate_data()` accepts, score via `evaluate()`), and (2) expose a `ModelAdapter.fit_and_submit(...)` that trains under the wall-clock budget and submits.* Ordered:
- [ ] `[H]` Create `bg-autoresearch` (repoforge-published, its own repo or `src/bg_autoresearch/` here). **Move out of `bg-fomo`**: `src/fomo/autoresearch/scorer.py` (+`__init__`/README), `src/workflow/autoresearch_run.py`, `src/fomo/models/candidate.py`, `Dockerfile.autoresearch`, `program.md`; **revert** the `pyproject.toml` plantbench pin. Net deletion from `bg-fomo`.
- [ ] `[H]` **Generalize the scorer**: `extract_spearman` → `extract_primary(metrics, stratum, metric_token, axis, higher_is_better)` so classification benchmarks (FRI) can be scored, not just regression.
- [ ] `[H]` Add the `ModelAdapter` protocol + `FomoAdapter` — imports `fomo` **as an installed wheel** (`fomo.data.datamodule.FomoDataModule` + `fomo.utils.plantbench.submit_predictions`, both verified in-wheel & model-class-free). This fills #59's `_train_and_submit` stub, now harness-side. **Pin the fomo wheel** + add a **build-time smoke test** that constructs `FomoDataModule` (guards the de-facto-API caveat).
- [ ] `[H]` **Parameterize the eval image** (`ARG MODEL_WHEEL`; tag `autoresearch-<model>:<tag>`) and the **orchestrator** (`orchestrator/entrypoint.sh`: `cd ml/bg-fomo` → `${REPO_SUBDIR}`; add `EVAL_IMAGE` + per-model `program.md`; RBAC/SA/quota need **zero** change). Give the brain the onboarded model's **source tree, read-only, for comprehension** — editable surface stays `candidate.py` only; runtime still uses the frozen wheel so source edits are ignored.
- [ ] `[H]` **Onboard a second target to prove agnosticism**: a `FriAdapter` via `fri.ops` (day-1 **epoch-bounded** — FRI has no `Timer` hook; flag the wall-clock-fairness gap, or add a one-line generic `callbacks=` hook to FRI) scored on a single scalar classification metric; and/or a `bg-ai/libs/plantbench/baselines/*` **statistical pipeline** wrapped as a non-DL adapter.
  - Verify: the *same* `bg-autoresearch` image + loop drives ≥ 2 targets with **zero autoresearch code in either model repo**. Scientific expansion (sharik / g1001, Phase 10 A100 scale-up) rides on this package, not on the v1 harness.

## Phase 10 — A100 scale-up (later, `bg-gpu-de`)
- [ ] `[H]` Repeat Phases 3–5 for `bg-gpu-de` **via `kubectl` (no Flux there)**: `az aks get-credentials -g bg-gpu-de-rg -n bg-gpu-de`; apply namespace/SA/RBAC/RQ; mirror snapshot to **germanywestcentral**; build an `autoresearch-fomo-a100:<tag>` image with `precision: bf16-mixed`; re-measure σ₀/budget for A100.
- [ ] `[H]` Raise the `a100` pool `max_count` 1→4 only if running parallel A100 jobs.
  - Verify: a smoke Job lands on `workload=gpu-a100` with `nvidia.com/gpu:1` and reports an A100-80GB.
