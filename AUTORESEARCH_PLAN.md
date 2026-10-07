# AUTORESEARCH_PLAN.md — Autonomous research loop for FOMO on AKS T4s

**Status (updated 2026-10-07):** the harness code now exists but has **not been run** — plantbench PR #60 (train‑based split), bg-ai PR #59 (FOMO harness), bg-infra #307 (merged: namespace/RBAC/quota/PVC) + #313 (orchestrator Deployment). No training, cluster‑GPU, S3, or Dagster *runs* have happened yet. Findings come from reading code/configs in `bg-ai/libs/plantbench` (the canonical plantbench; the standalone `../PlantBench` is **stale**), `../bg-ai`, `../bg-infra`, and this `autoresearch/` reference harness.

**What this is.** A Karpathy-style autoresearch loop: a headless Claude Code agent edits one model file, launches a fixed-budget train+eval job on the AKS T4 cluster, reads a single validation score, and keeps or discards the change against a measured noise floor. Evaluation is frozen mechanically; a locked test set is never shown to the agent; everything to production goes through a human-reviewed PR.

**How to read it.** Step 1 is the repo survey (every claim cited). Step 2 is the 12-section plan. Assumptions are flagged inline as **[ASSUMPTION]**; things I could not determine are in §12.

**Convention for paths.** `PB/` = `../PlantBench`, `FOMO/` = `../bg-ai/ml/bg-fomo`, `BGAI/` = `../bg-ai`, `INFRA/` = `../bg-infra`, `REF/` = this `autoresearch/` dir.

---

# Step 1 — Repo survey

## 1A. Benchmark repo (PlantBench)

### Which benchmarks exist
PlantBench registers ~15 concrete benchmark classes (13–15 registry entries) across two task types — **classification** and **regression** — keyed by `BenchmarkConfig(name, split, task_type)` (`PB/src/plantbench/benchmarks/registry.py:7-33`, `PB/src/plantbench/benchmarks/__init__.py:8-48`). Metric direction: **higher is better** for R²/Pearson‑r/Spearman‑r/AUROC/hits@k/precision@k/directional‑accuracy; **lower is better** for MAE/MSE/RMSE/Brier/log‑loss (`PB/src/plantbench/metrics/regression.py:32-80`, `.../roc.py:24-80`, `.../rank_derived_metrics.py:22-96`, `.../calibration.py:27-60`).

| # | Benchmark (registry key) | Measures | Metrics | Dir. |
|---|---|---|---|---|
| 1 | `protein_function_annotation` (random / curated_neg_pos_ratio), classification | protein → GO/EC descriptor | hits@k, AUROC, PR‑curve, calibration | ↑ |
| 2 | `gene_shortlisting_athaliana` / `gene_shortlisting_gmax`, classification | gene → phenotype | hits@k, cumPos@k, prec@k, AUROC, any@k | ↑ |
| 3 | `synthetic_grn_prediction` / `dream5_grn_prediction`, classification | TF → target edge | hits@k, AUROC, PR, calibration | ↑ |
| 4 | `g1001_eqtl_detection`, classification | SNP → gene eQTL | hits@k, AUROC, PR | ↑ |
| 5 | `qtl_prioritisation`, classification | gene → QTL | hits@k, AUROC, PR | ↑ |
| 6 | `dream5_gene_expression_prediction`, regression | sample → gene expr | R², MAE, MSE, Pearson‑r | ↑/↓ |
| 7 | `g1001_gene_expression_prediction`, regression | variant → gene expr | R², MAE, Pearson‑r, Spearman‑r, directional acc (per‑sample & per‑gene) | ↑/↓ |
| 8 | `ms_gene_expression_prediction`, regression | multi‑species variant → expr | as #7 | ↑/↓ |
| 9 | **`dream_sequence2expression_prediction`, regression** | **DNA sequence → expression** | **R², MAE, MSE, Pearson‑r, Spearman‑r** | ↑/↓ |
| 10 | `plant_promoter_strength_prediction` (STARR‑seq), regression | promoter seq → strength | R², MAE, MSE, Pearson‑r, Spearman‑r | ↑/↓ |
| 11 | `sharik_expression_prediction`, regression | tissue → gene expr | R², MAE, Pearson‑r, Spearman‑r (per‑tissue & per‑gene) | ↑/↓ |
| 12 | `synthetic_grn_prediction` (regression split) | TF → target weight | R², MAE, MSE, Pearson‑r | ↑/↓ |

Concrete files: `sequence_to_expression.py:30-131`, `gene_expr_prediction.py:38-449`, `plant_promoter_strength.py:28-88`, `sharik.py:38-272`, `protein_annotation.py:27-122`, `grn_prediction.py:29-153`, `eqtl_prediction.py:31-73`, `qtl_prioritisation.py:22-61`, `gene_shortlisting.py:102-138` (all under `PB/src/plantbench/benchmarks/`).

### How a benchmark is run — entry point, inputs, contract
High‑level flow (`PB/src/plantbench/benchmarks/base.py`):
```python
bm = Benchmark(name="dream_sequence2expression_prediction").load(version="2025-06-02_14-16-47")  # base.py:229-280
bm.submit(data=adata, submission_name="cand_<sha>", metadata={...})                              # base.py:282-291
results = bm.evaluate(("cand_<sha>", "<date>"))                                                  # base.py:351-525 → _evaluate 575-615
```
- **Model↔benchmark contract.** A model must produce an `anndata.AnnData` with `obs` = source entities, `var` = target entities, `X` = score matrix. Classification scores must be in `[0,1]` (`base.py:990-991`); regression scores are unbounded. `validate_data()` requires the submission's `(source,target)` pairs to match the test pairs exactly (`base.py:906-993`). `.submit()` is **write‑only** (stores the AnnData to S3/local); `.evaluate()` loads the hidden `test_labels` parquet, runs each metric, returns `EvaluationResults(metrics: dict[str,float], artifacts: list[path])`.
- **Scoring is CPU‑only** — pure numpy/scipy/sklearn/statsmodels, no torch/jax/GPU imports (`PB/src/plantbench/metrics/*.py`). Complexity ~`O(M×N)`; seconds to ~1 min for typical test sizes.

### Where the data comes from, size, versioning
- Data lives in **AWS S3**: `s3://bg-data-prd/data/gold/benchmarks/<ASSET>/<timestamp>|<n>.<sha256>.yml`, a versioned YAML that in turn lists S3 paths for `train` / `test` / `test_aux` / `test_labels` (`base.py:245-280`; examples in `sharik.py:40-44`, `protein_annotation.py:30-32`, `gene_expr_prediction.py:40-46`). Versions are **immutable** (timestamp + sha256). First access downloads and caches to `~/.plantbench/<name>__v_<version>/` (`base.py:886-904`; `PB/.env.example`).
- **Sizes are not stated in code** — unknown from repo alone (§12). Partition suffixes (`__1000/__2000/__6000`) hint at sample/variant counts (`eqtl_prediction.py`).
- Dagster asset names feeding benchmarks appear only as the gold‑layer asset path segments above; FOMO/FRI training assets are referenced as `silver/...` keys in `BGAI/ml/bg-fri/src/fri/schema/data_configs.py:78-114`.

### Splits, level, leakage
- **Splits are PAIR‑level** (`(obs,var)` tuples), deterministic and YAML‑locked (`base.py:245-280`, `pairs.py:10-124`). Three groups only: `train` (many assets), `test` (inputs), `test_labels` (hidden, `base.py:543-566`). **There is no separate validation set** (`README.md:10-20`).
- **Stratification is optional, not default** (`base.py:360,559,654-681`; `stratification.py:49-198`). The default unstratified path has **no automatic guard** against homologous/paralogous genes, same donor/accession, batch/sequencing‑centre, or SNP LD leakage (verified: `verify:split-leakage` = confirmed). Opt‑in tools exist: `get_stratification_by_train_overlap()` (`gene_expr_prediction.py:110-163`), `get_stratification_by_dataset()` and `set_snps_in_ld_to_true()` (`eqtl_prediction.py:244-312`), and `ObsVarStratification` for explicit pair filtering (`stratification.py:121-198`).
- **Leakage flags:** for `g1001_*` / `ms_*` (real accessions) the default path *will* leak across accession/batch/LD/orthologs unless stratified. For `dream_sequence2expression_prediction` the sequences are **synthetic DNA** (lowest leakage risk) — the main concern there is the reference‑subtraction preprocessing (`compute_expression_difference`, `sequence_to_expression.py:81-131`).

### Held‑out test set lockable from the agent
Yes — and it falls out of the benchmark‑owned split. `plantbench`'s `train_validation_split()` carves a decile‑stratified **`validation` subset out of the DREAM `train` pairs** (the agent optimises this, scored via `score_validation()`) and leaves a disjoint `train` remainder to train on. The **official DREAM `test` set is never touched by the loop** — scoring the whole test set is a rare, human‑only `evaluate()` ("locked test"), which is exactly what keeps a submission comparable with every other submission. See §4.

### Seeds and nondeterminism
`np.random.seed(42)` is the default in `calibration.py:47` and `benchmarks/utils.py:57`; `split_indices()`/`sample_negatives()` call `np.random.shuffle` without an explicit seed (`utils.py:582-619`). A reproducibility test exists for shuffling only (`tests/benchmarks/test_shuffle_anndata_scores.py:126-138`). **There is no global‑seed control in `evaluate()` and no measured run‑to‑run variance** — the noise floor must be measured by us (§4).

### Typical runtime / hardware
Not documented. Scoring is CPU‑only and fast (seconds–minutes). Training runtime is model‑side (FOMO), see §1B.

### Eval vs model separation
Clean. `metrics/` is pure evaluation; `benchmarks/base.py` orchestrates generically; benchmark subclasses only declare entity pairs + `default_metrics`; stores (`submission_store.py`, `result_store.py`) are model‑agnostic. No model/training code in the eval path. Baselines live separately in `BGAI/libs/plantbench/baselines/` and are not imported by the eval pipeline.

> **Note — two plantbench copies.** `../PlantBench` is the standalone repo; `BGAI/libs/plantbench` is a vendored, independently‑published copy (v1.39.0) that differs slightly (`artifact_format`, `get_stratifications_by_organism`). FOMO depends on the **published package**, not the vendored source — see §1B. **[2026-10-06 correction]** Treat the standalone `../PlantBench` as **STALE/old**: the canonical, published-to-repoforge source is **`bg-ai/libs/plantbench`**. Read/verify plantbench facts there, not in `../PlantBench`.

## 1B. Model repo (bg-ai, FOMO)

### Models in bg-ai
| Model | Kind | Framework | GPU | Evaluated by |
|---|---|---|---|---|
| **`ml/bg-fomo`** (FOMO) | DL, DNA sequence→expression | PyTorch + **Lightning** + **Hydra** + pydantic | yes (optional) | PlantBench (DREAM s2e, g1001, eQTL, PPS, GSL) via `BenchmarkHook` |
| `ml/bg-fri` | DL, protein‑function | PyTorch + Lightning + torch‑geometric | yes | PlantBench (protein_function) |
| `lm/rbioscope` | LLM workflow (OpenAI) | — | no | n/a |

Sources: `FOMO/README.md`, `FOMO/pyproject.toml`, `FOMO/src/fomo/models/base.py:7,75`; `ml/bg-fri/pyproject.toml`; `lm/rbioscope/*`.

### FOMO specifics
- **Architecture/IO.** `fomo.models.base.Fomo(pl.LightningModule)` (`src/fomo/models/base.py:75`). Input = DNA as `seq2int`, 5 channels (`configs/data/benchmark_s2e.yaml:13-14`); output = expression, default `out_channels: 1` (`...:15`, `base.py:214`). Architectures: BHI (CNN+LSTM), transformer variants, PSAGEnet (`configs/arch/*.yaml`, `src/fomo/models/*.py`).
- **Entry points.** Local: `python src/workflow/pipeline.py [hydra overrides]` → `train()` in `src/workflow/train.py:219-246`. Also `resume.py`, `hyperparameter_train.py`, and `sagetrain.py` (SageMaker). Config = **Hydra** composition (`configs/arch`,`/data`,`/training`) validated by pydantic (`src/fomo/schema/train_config.py`); hyperparameters set via CLI overrides, e.g. `training.max_steps=100 data.train_batch_size=32 training.precision=16-mixed`.
- **Budget knobs** (`src/fomo/schema/train_config.py:43-64`): `max_epochs`(50 full/2 quick), `max_steps`(-1 default; 100 in `quick_test.yaml`), `val_check_interval`, `limit_val_batches`, `accumulate_grad_batches`, `max_train_size` (`datamodule.py`). **Not exposed:** `limit_train_batches`, `fast_dev_run`, and **no wall‑clock budget** (unlike this reference harness's fixed 300 s).
- **Precision.** `precision: Literal["16-mixed","32-true","bf16-mixed"] = "32-true"` (`train_config.py:59`); `full_train.yaml:10` uses `16-mixed`. **bf16 is a dangling option, used in zero real configs** (verified `verify:precision-t4` = refuted). On **T4, use `16-mixed` (fp16)**; bf16 is unsupported on T4 and must be blocked (see §6).
- **Memory vs 16 GB.** BHI ≈ 35 M params, transformer ≈ 1.5 M; at fp16, 1001g@2000bp ≈ 0.72 GB, DREAM@110bp ≈ 0.13 GB with batch 64 — **fits 16 GB with large headroom** (verified `verify:fomo-memory-16gb` = confirmed). No gradient checkpointing exists (not needed at v1 sizes).
- **Benchmark hook.** `fomo.data.hooks.benchmark.BenchmarkHook` loads a PlantBench benchmark, copies its data into the datamodule, and on `on_predict_complete()` calls `submit_predictions()` → `benchmark.submit()` (`src/fomo/data/hooks/benchmark.py:92-226`, `src/fomo/utils/plantbench.py:153-237`). **`benchmark.evaluate()` is never called in the training/inference path** (verified `verify:eval-freezable` = confirmed) — only in an experimental sandbox file.

### Dockerfiles, CI, k8s, tracking
- **Dockerfile** (`FOMO/Dockerfile`): base = **AWS ECR SageMaker** image `pytorch-training:2.5.1-gpu-py311-cu124-ubuntu22.04-sagemaker`; installs via `uv pip install --system .` with `FORGE_API_KEY` for the repoforge index.
- **CI** (`BGAI/.github/workflows/*`): lint/type/test (coverage ≥60 %) and **publish libs to repoforge**. **No workflow builds or pushes any Docker image.** Image is built/pushed manually/externally today.
- **Orchestration:** **AWS SageMaker only** (`sagetrain.py` `instance_count=1`, `max_run=172800`; `launch_tuner.py`, `tuner.py` with boto3). **No Kubernetes manifests anywhere in bg-ai** → running FOMO on AKS is net‑new work.
- **Tracking:** **MLflow** (`MLFLOW_TRACKING_URI`, prod `https://mlflow-tfm.prd.int.graphica.bio/`; `src/fomo/utils/misc.py:100-104`). Best val metric logged as `best/val/loss_epoch` (`src/fomo/utils/lightning.py:164-200`). No W&B.

### Dependency on PlantBench
`plantbench>=1.36.0` from the private **repoforge** index (`FOMO/pyproject.toml:18,67`); imported directly (`from plantbench.benchmarks import BaseBenchmark` in `predict.py:35-40`). **This is the linchpin for freezing eval**: eval is a version‑pinnable package, not inlined model code. `BGAI/uv.lock` pins the exact resolved version.

---

# Step 2 — The plan

## 1. Recommended v1 target

**Benchmark: `dream_sequence2expression_prediction` (version `2025-06-02_14-16-47`). Model: FOMO (BHI arch).** (verified `verify:variance-noisefloor` = confirmed.)

Why this pair:
- **Direct task fit** — FOMO *is* a DNA‑sequence→expression model; DREAM s2e is exactly that task (`sequence_to_expression.py:30-131`).
- **Fast** — short sequences (110 bp), small model, CPU scoring in seconds → many runs per overnight session.
- **Stable, high‑signal metric** — regression correlations (Spearman‑r/Pearson‑r) are bounded `[-1,1]` and robust; preferred over R² (which can go negative and is noisier).
- **Lowest leakage risk of any benchmark** — sequences are *synthetic*, so there is no donor/accession/batch/ortholog/LD contamination to engineer around (contrast with `g1001_*`). This lets v1 focus on the harness, not on stratification correctness.

Runner‑ups (later phases):
1. `plant_promoter_strength_prediction` (STARR‑seq, version `2025-06-11_17-53-05`) — also sequence‑based, small, 6 condition stratifications for generalisation probing.
2. `g1001_gene_expression_prediction` — larger, real accessions; **requires** `get_stratification_by_train_overlap()` to avoid accession/gene leakage. Good v2 once stratification is wired in.
3. `plant_promoter_strength` ↔ FOMO, or `bg-fri` ↔ `protein_function_annotation` as a second independent loop once v1 is proven.

## 2. Editable surface

Mirror the reference harness's one‑file discipline (`REF/program.md:25-32`: agent edits `train.py` only, `prepare.py` frozen).

**v1 — the agent may edit exactly ONE file:**
- `FOMO/src/fomo/models/candidate.py` **[NEW]** — a self‑contained `LightningModule`/network the agent rewrites freely (architecture, optimiser, loss, forward/training step, hyperparameters). It must expose a fixed class name (`CandidateModel`) and accept the frozen datamodule's tensor shapes.

**Off‑limits (mechanically enforced, §3/§7):**
- The frozen scorer, the benchmark‑owned split (`plantbench`), datamodule, benchmark hook, budget, and all `configs/data/*` + `configs/training/*`.
- `FOMO/src/workflow/autoresearch_run.py` **[NEW]**, `FOMO/src/fomo/autoresearch/scorer.py` **[NEW]**, `FOMO/src/workflow/configs/experiments/autoresearch_dream.yaml` **[NEW]**.
- The container image, the Kubernetes manifests, `pyproject.toml`/deps, and everything in PlantBench and bg-infra.

The agent cannot add dependencies (same rule as `REF/program.md:30`): only what is already in the frozen image.

## 3. Harness design

```
Agent VM (headless Claude Code)                     AKS bg-kubernetes (italynorth)
┌───────────────────────────────┐                  ┌───────────────────────────────────────┐
│ edits candidate.py            │   kubectl create │ Job (ns: autoresearch)                 │
│ git commit on branch          ├─────────────────►│  image: ACR autoresearch-fomo:<frozen> │
│ render Job yaml, apply        │                  │  entrypoint: autoresearch-run (FROZEN) │
│ kubectl logs / wait           │◄─────────────────┤   1. load candidate.py (ConfigMap)     │
│ read score.json               │   logs + PVC     │   2. train CandidateModel, fixed budget│
│ keep (advance) / discard(reset)│                 │   3. evaluate() → Spearman (validation)│
└───────────────────────────────┘                  │   4. write score.json (stdout + PVC)   │
                                                    │  GPU: 1× T4, data PVC mounted read-only│
                                                    └───────────────────────────────────────┘
```

**Packaging a candidate — decided: per-run ConfigMap (Q9), not a git checkout in the pod and not an image layer.** The candidate is *data*, never baked into the image. Each run the orchestrator writes `candidate.py` into a per-run ConfigMap (`autoresearch-candidate-<commit>`) that the Job mounts **read-only at `/candidate`**; the frozen entrypoint imports `CandidateModel` from that path, while importing the scorer/datamodule/budget and the **benchmark-owned split** (`plantbench`) **from the installed frozen package in the image** — so branch edits to any of those are ignored at runtime (import precedence is the whole trick). The ConfigMap keeps the Job pod **credential-less** (no git token in-cluster). No per-run image build, no registry push, no docker-in-docker. Reproducibility = `(frozen image digest) + (git commit of candidate.py) + (benchmark_version, split_seed, val_fraction)`.
*Promotion only:* when a candidate is **kept**, a trusted CI step may bake it into an immutable image (`FROM autoresearch-fomo@sha256:… ; COPY candidate.py`) as an archival artifact for the A100 scale-up / eventual PR — rare, CI-built, never the agent.

**How evaluation stays frozen (mechanical, not instructions).**
- The scorer, the **benchmark‑owned split** (`plantbench` `train_validation_split` + `score_validation`), datamodule, and budget are **baked into the image** / pinned via `plantbench` and imported from the installed package. The agent's branch edits to those paths never reach the running job.
- The image is built **once** and pushed to `biographicaregistry.azurecr.io/autoresearch-fomo:<frozen-tag>` by an admin/CI, then the tag is made **immutable** (`az acr repository update --image ... --write-enabled false`, pattern from `INFRA/terraform/azure/cicd-acr.tf`). The agent's identity has **no AcrPush** — ACR push is gated to CI for repos `bg-dagster-assets`/`bg-data`/`bg-mr` only (`cicd-acr.tf:26-81`), not bg-ai and not the agent. Nodes have **AcrPull only** (`acr.tf:20-27`). So the agent literally cannot rebuild or alter the eval image.
- `plantbench` is pinned to an exact version in the image via `BGAI/uv.lock`; the same locked version computes every score.

**Minimum refactor to separate eval from model (concrete tasks):**
1. **[T1]** Use the **benchmark‑owned split** that lives in `plantbench` (bg-ai PR #60): the frozen entrypoint calls `benchmark.train_validation_split(seed=42, val_fraction=0.2)`, which deterministically **carves a decile‑stratified `validation` subset out of the DREAM `train` pairs** (what the loop optimises) and leaves a disjoint `train` remainder (what the model trains on). **The official DREAM `test` set is never touched by the loop** — keeping it whole is exactly what makes a submission comparable with every other submission (Paride's review: never iterate against the test set). There is **no local split manifest and no `make_autoresearch_split.py`** — the split is derived at runtime from the pinned snapshot's train pairs + its label table and is reproducible from `(benchmark_version, seed, val_fraction)` (never parquet row order; NaN‑labelled pairs are dropped and conflicting duplicate labels collapsed by a pinned sort). **Split method (Q4 — confirmed with colleagues):** DREAM sequences are *synthetic & independent*, so a decile‑balanced partition of the labeled train pairs is leakage‑safe. **Review gate (your ask):** the split METHOD + parameters (seed, val_fraction) are reviewed in the **plantbench PR (#60)** before the FOMO pin is bumped and the image frozen — the human checkpoint on principles #2/#5 (locked test + no leakage). The whole‑test **locked test** is a separate, rare, human‑only `evaluate()` run; the loop itself never scores it.
2. **[T2]** `FOMO/src/fomo/autoresearch/scorer.py` is a **thin, pure extractor**: scoring runs through `plantbench`'s public `score_validation()` (which reuses the benchmark's own preprocessing + default metrics — the same KIND of number the locked‑test `evaluate()` reports), and the scorer just reads the `validation` **Spearman‑r** float (key `validation.Spearman-r.axis1`) plus the other scalar metrics (Pearson‑r/R²/MAE) out of the result mapping. Stdlib‑only, no model imports, no S3 — so it stays trivially frozen and unit‑testable.
3. **[T3]** `FOMO/src/workflow/autoresearch_run.py`: load the pinned benchmark, get `splits = benchmark.train_validation_split(...)` → `{train, validation}`, instantiate `CandidateModel`, train on `splits["train"]` under a **wall‑clock budget** via a Lightning `Timer(duration=timedelta(seconds=budget_seconds))`, predict the `splits["validation"]` pairs (plus any reference sequences DREAM's preprocessing subtracts) into a long‑form predictions frame, then score it via `benchmark.score_validation(val_preds)` — which reuses the benchmark's **own** preprocessing + default metrics — extract Spearman‑r (key `validation.Spearman-r.axis1`), write `score.json` to stdout and `/out/score.json`. Exit 0 on success, 1 on crash/NaN. The frozen split seed (42) is distinct from the per‑run training seed. The official `test` set is never submitted or scored here.
4. **[T4]** `FOMO/src/workflow/configs/experiments/autoresearch_dream.yaml` — frozen Hydra experiment. It pins the snapshot as literals: `benchmark_version: "2025-06-02_14-16-47"`, the benchmark‑split params `split: {seed: 42, val_fraction: 0.2}`, `precision: 16-mixed`, candidate arch, and `budget_seconds`. No `manifest_sha256` / split paths (the benchmark owns the split). Off‑limits; baked into the image so branch edits to it are ignored at runtime.
5. **[T5]** Precision guard (do **not** delete `bf16-mixed` — the A100 cluster needs it, see §6 → *Multi-cluster*). Keep the `Literal` in `train_config.py:59`, but (a) pin the correct precision in each **per-cluster** frozen experiment config (T4 → `16-mixed`, A100 → `bf16-mixed`), and (b) add a one-line runtime assertion in the entrypoint that **rejects `bf16-mixed` when the detected GPU is a T4** (Turing → no bf16), so a mis-targeted config fails fast instead of silently degrading to fp32.
6. **[T6]** Build + push + lock the frozen image. **Owner: a human admin (or a one‑off CI job), out of band — never the agent**, which has no AcrPush. Build `FOMO/Dockerfile.autoresearch` (a standard CUDA‑12.4 PyTorch base, *not* the SageMaker/ECR base; `plantbench` pinned via `BGAI/uv.lock`), `az acr build`/`docker push` to `biographicaregistry.azurecr.io/autoresearch-fomo:<frozen-tag>`, then lock the tag: `az acr repository update --name biographicaregistry --image autoresearch-fomo:<frozen-tag> --write-enabled false`. Re‑running the loop against a new eval definition requires a human to build+lock a new tag.

## 4. Metric and acceptance rule

- **Campaign goal (v1):** a single overnight campaign whose success bar is **≥ 5 % relative improvement in validation Spearman‑r over the measured baseline μ₀** (e.g. μ₀ = 0.40 → target ≥ 0.42). This is the *campaign-level* goal — it decides when v1 is "done"; it is distinct from the *per-candidate* keep/discard gate below (which decides whether any one edit survives). Hitting +5 % (or exhausting the night) ends the v1 campaign; the next step is the v2 refactor (§10/§13), **not** more v1 runs on the throwaway harness.
- **Primary score:** **Spearman‑r of predicted vs measured expression on the benchmark‑owned `validation` split** (a decile‑stratified subset of the DREAM **`train`** pairs), computed through `plantbench`'s public `score_validation()` (the benchmark's own preprocessing + default metrics) and read out by the thin frozen scorer — so the inner‑loop number is definitionally the same KIND of metric the locked‑test `evaluate()` reports. **Higher is better.** Secondary (logged, not used for keep/discard): Pearson‑r, R², MAE.
- **Noise floor (measure first, before any editing).** Train the *baseline* `CandidateModel` `K = 10` times with seeds `0..9` at the exact fixed budget; record μ₀ (mean) and σ₀ (std) of Spearman‑r on `val'`. This is a one‑time calibration run (≈10 runs × per‑run budget; see §6). There is **no existing variance data** in the repos, so this must be done (verified).
- **Keep/discard threshold (two‑stage, to resist seed noise and benchmark overfitting):**
  - *Explore* at 1 seed for speed. If a candidate's single‑seed score does not beat the current best by at least σ₀, **discard** (git reset), log, move on.
  - *Confirm* promising candidates at `n = 3` seeds. **Keep** only if `mean₃(candidate) − mean(current_best) > 2·σ₀/√3` (≈ `1.15·σ₀`). Otherwise discard. (σ₀ = the empirical standard deviation of Spearman‑r across the 10 baseline seeds; `2·σ₀/√3` is two standard errors of a 3‑seed mean.)
  - Apply the reference harness's **simplicity criterion** (`REF/program.md:37`): a tiny gain that adds ugly complexity → discard; equal‑or‑better with *less* code → keep.
- **Locked test cadence & audience.** The **locked test is the whole, untouched official DREAM `test` set**. A human builds a submission from the current‑best candidate and scores it the normal way — `benchmark.submit(preds, name)` then `benchmark.evaluate((name, date))` — **at most once per day or per 5 kept improvements**, whichever is rarer. Results go to a **human‑only** location (MLflow experiment `autoresearch-locked-test`, or `locked_test_results.tsv` outside the agent's workdir) and are **not** fed back into the agent's `results.tsv`/notes. Divergence (`validation` keeps climbing while the locked test stalls/regresses) = benchmark overfitting → human intervenes. The loop itself **only ever scores the train‑derived `validation` subset** (via `score_validation`); only the human ever touches the test set.

## 5. Data

- **Snapshots to freeze.** The DREAM s2e benchmark `2025-06-02_14-16-47` train/test/test_labels, materialised once from the immutable S3 YAML + data to a local snapshot. The `train`/`validation` split is **not** a separate artifact — `plantbench` derives it deterministically at runtime from the train pairs + the label table. Pin by `(benchmark_version_string, split_seed, val_fraction)`.
- **Where to cache relative to AKS.** Mirror the frozen snapshot **once** into Azure (same region as the cluster, `italynorth`) and mount it **read‑only** into every Job:
  - v1 (one job at a time): a pre‑populated **PVC on `fast-ssd`** (Azure Premium Disk, `INFRA/flux-infra-azure/infra-storage-classes.yaml`), access mode **RWO**, mounted `readOnly: true` at `/data`. v2 (concurrent jobs): switch the PVC to **`azurefile-nfs-rwx`** (RWX) so multiple jobs share one read‑only copy.
  - On‑PVC layout the frozen entrypoint expects: the pinned DREAM snapshot (`train`, `test`, `test_labels`) under `/data/dream_<version>/`, laid out as `plantbench`'s loader/cache expects. The label table (`test_labels`) covers the train pairs too, so `score_validation` reads the `validation` labels straight from it — the loop never touches the `test` inputs. The `test` set is present only for the separate, human‑only locked‑test `evaluate()` run against this same snapshot.
  - The agent's identity has **read‑only** access to this data and **no** write path to it.
- **Size — measured (Q1 resolved; read-only `aws s3 ls`, `standard` profile, 2026-10-05).** DREAM s2e (v1) = **~0.59 GB** total (`SYNAPSE__DNASequence__DREAM_s2e_prediction_benchmark_*`: train 560 MB, test 2.6 MB, labels 3.9 MB, config 2 KB — version `2025-06-02_14-16-47` confirmed). Runner-ups: STARR-seq promoter ≈ **33 MB** (latest version 2025-11-17); multispecies variant-expression train ≈ **18.4 GB**; 1001G arabidopsis raw ≈ **1.1 GB**. → **PVC sizing: 10 GB covers v1 + STARR-seq comfortably; ~30 GB when adding the v2 multispecies/g1001 benchmarks.** Egress math: the one-time DREAM mirror is ~0.6 GB (~$0.05, negligible); *without* the mirror a job re-pulls 560 MB each (~28 GB/night at 50 runs) — so the mirror pays for itself on night one.
- **Cross‑cloud egress.** Data is in **AWS S3 eu‑west‑2** (account 041738973800); compute is **Azure AKS italynorth** — different clouds (verified `verify:crosscloud-egress` = confirmed). Today PlantBench pulls from S3 per‑pod via boto3 with no Azure mirror, so a naive loop pays AWS egress (~$0.02/GB) **every run**. **Mitigation (required for v1): one‑time S3→Azure Blob/PVC mirror**, then all Jobs read local Azure storage → egress paid once, not per iteration, and training start latency drops to local‑disk I/O. Use the existing OIDC‑federated `bg-dagster-prod` AWS role (`INFRA/terraform/aws/oidc-federation.tf`) for the one‑time copy; keyless Azure Blob via the `bg-nextflow` workload identity (`INFRA/terraform/azure/batch.tf:76-101`). **(Q8 resolved: no constraints → the S3→Azure Blob copy is the chosen approach; one copy per region — italynorth and germanywestcentral.)**

## 6. Compute

**Per‑run budget.** Fixed **wall‑clock training budget** (fair across candidate architectures of different speeds, matching the reference's 300 s philosophy). **v1: 10 min train (`--budget-seconds 600`) + ~1 min score.** Reasoning: DREAM is small so 10 min gives a stable, non‑trivial baseline while allowing ~4–5 runs/hour → ~40–50 runs overnight on one T4. Enforce in‑process with a Lightning `Timer(duration=timedelta(seconds=budget_seconds))` callback (a `timedelta`, to avoid any ambiguity in Lightning's `DD:HH:MM:SS` string form); enforce at the cluster with `activeDeadlineSeconds`.

**T4 changes.** `precision: 16-mixed` (fp16) always (never bf16 on T4 — guarded, not deleted, §3‑T5); batch 64 @110 bp fits 16 GB with headroom; `torch.set_float32_matmul_precision("medium")` already set (`src/fomo/schema/initialiser.py:145`).

**Kubernetes Job template** (new file `INFRA/flux-infra-azure/autoresearch/job-template.yaml`; the agent renders `<commit>` per run):
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  generateName: autoresearch-fomo-
  namespace: autoresearch
spec:
  backoffLimit: 0                 # no silent retries; a crash is a crash (results.tsv status)
  activeDeadlineSeconds: 1200     # 20 min hard cap (10 min train + score + startup margin)
  ttlSecondsAfterFinished: 1800   # auto-clean finished Jobs after 30 min
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: autoresearch-runner
      nodeSelector: { workload: gpu-t4 }                 # matches gpu-t4 NodePool
      tolerations:
        - { key: sku, value: gpu, effect: NoSchedule }   # matches NodePool taint
      containers:
        - name: run
          image: biographicaregistry.azurecr.io/autoresearch-fomo:<frozen-tag>   # pull-only
          command: ["autoresearch-run"]
          args: ["--commit", "<commit>", "--budget-seconds", "600"]
          # v1 (Q5): NO MLflow — frozen scorer writes score.json; orchestrator records results.tsv.
          # Later: add an agent-scoped MLFLOW_TRACKING_URI (never prod) + experiment here.
          env: []
          resources:
            requests: { cpu: "4", memory: "16Gi", nvidia.com/gpu: "1" }
            limits:   { cpu: "8", memory: "28Gi", nvidia.com/gpu: "1" }  # 1× NC4/8as_T4_v3
          volumeMounts:
            - { name: candidate, mountPath: /candidate, readOnly: true }  # per-run ConfigMap (§3)
            - { name: data, mountPath: /data, readOnly: true }
            - { name: out,  mountPath: /out }
      volumes:
        - { name: candidate, configMap: { name: autoresearch-candidate-<commit> } }
        - { name: data, persistentVolumeClaim: { claimName: autoresearch-data-ro } }
        - { name: out,  emptyDir: {} }
```
Grounded in `INFRA/flux-infra-azure/nap-nodepools.yaml:136-198` (label/taint/SKUs/`nvidia.com/gpu` cap 8) and `gpu-device-plugin.yaml`. **MLflow is deferred (Q5):** v1 runs with **no tracking server** — the frozen scorer emits `score.json` (stdout + `/out`) and the orchestrator records `results.tsv`, which is enough for keep/discard. The frozen runner must therefore init FOMO's trainer **without an MLflow logger** in v1 (null/CSV logger). When your MLflow server is ready, add an **agent-scoped** `MLFLOW_TRACKING_URI` (never prod) + experiment to the Job env.

**Max concurrent jobs.** The `gpu-t4` pool is capped at **8 T4s total and is shared** with Dagster `fri_finetuning` (4‑GPU). **v1: 1 concurrent job** (`ResourceQuota requests.nvidia.com/gpu: "1"`, §7). v2: raise to 2–4 after proving isolation. Max concurrent = `quota.gpu / gpus_per_job`.

### Multi-cluster & per-hardware (T4 italynorth · A100 Germany West Central)

Confirmed from `bg-infra/terraform/azure-gpu-de/` + live `az` checks (2026-10-05). **The Germany cluster is now created:** `bg-gpu-de` (RG `bg-gpu-de-rg`, germanywestcentral, k8s 1.35, state Succeeded); fixed system pool 1× `Standard_D4s_v7`.
- **Cluster:** standalone A100 cluster in **germanywestcentral**, separate from italynorth (own RG/state), **no NAP/Karpenter, no Flux — driven by plain autoscaling node pools + `kubectl`** (`azure-gpu-de/aks.tf`).
- **GPU pool `a100`** (live `az aks nodepool`): `Standard_NC24ads_A100_v4` (1× A100 80 GB), **scale-to-zero**, `min 0` / **`max 1`** / count 0 today → **only 1 A100 until `max_count` is raised** (bump to 4 to use the full 96-vCPU quota; scale-up 0→1 takes minutes). Label **`workload=gpu-a100`**, taint **`sku=gpu:NoSchedule`** (both confirmed live). Job contract: `nodeSelector {workload: gpu-a100}` + toleration `{key: sku, value: gpu, effect: NoSchedule}` + `nvidia.com/gpu: 1`.
- **Quota (live `az vm list-usage`, germanywestcentral):** `Standard NCADS_A100_v4` = **96 vCPU** (H100 / NDA100 families = 0, i.e. no H100 option) → the quota permits **up to 4 concurrent 1-GPU A100 jobs** (or one `NC96ads_A100_v4`, 4× A100 DDP) — **but the deployed `a100` pool's `max_count` is 1 today, so raise it to 4 to realise this.** Regional vCPU limit 256 — no conflict.
- **ACR:** `azure-gpu-de/acr.tf` adds AcrPull for this cluster's kubelet on the existing `biographicaregistry` + **Premium geo-replication to germanywestcentral** → the frozen image pulls locally, still push-less.
- **For contrast, live italynorth T4 quota:** `Standard NCASv3_T4` = **256 vCPU, 132 already in use** (shared with Dagster `fri_finetuning`); the real autoresearch cap there is the NodePool's `nvidia.com/gpu: 8`.

It runs the loop too, but as a **separate experiment family, not an extension of the T4 loop** — comparability (principle #3) breaks across hardware:
- **Precision:** T4 (Turing) → `16-mixed`; A100 (Ampere) → `bf16-mixed` (more stable). Pinned per-cluster in the frozen config (§3‑T5), never by the agent.
- **Budget & noise floor:** A100 is ~10–20× faster, so the same wall-clock trains far more steps and bf16-vs-fp16 numerics shift σ₀ → **each cluster gets its own re-measured baseline and its own `budget_seconds`** (configurable — Q7).

**Rule: one hardware target per benchmark loop; baseline + all candidates stay on that cluster. Never compare a T4 score to an A100 score.**

Per-cluster setup (Q6, Q12 — namespace in both, data mirrored to both):
- a dedicated `autoresearch` namespace + `autoresearch-runner` SA + RBAC + ResourceQuota on **each** cluster (italynorth via Flux; **germanywestcentral via `kubectl`**, since no Flux there);
- a per-cluster frozen config + image tag (e.g. `autoresearch-fomo-a100:<tag>` with `bf16-mixed`); geo-replicated ACR already serves it pull-only;
- **mirror the frozen snapshot into germanywestcentral** Azure Blob (origin AWS S3 eu-west-2) so A100 jobs read locally;
- **kill switch on Germany differs (no Flux/NAP):** `az aks nodepool update -g bg-gpu-de-rg --cluster-name bg-gpu-de -n a100 --min-count 0 --max-count 0` (stops GPU scale-up), or `kubectl -n autoresearch delete jobs --all`, or ResourceQuota gpu=0. (`min_count=0` already means idle=free.)

**Division of labour.** A100s are scarce/expensive; the inner loop is many *small, fast* experiments where T4s shine. Use **T4 (italynorth) for broad search**; use the **A100 cluster for (a) scaling up a kept winner, (b) models too big for 16 GB, (c) heavier context / multi-tissue benchmarks** (sharik, multi-tissue g1001). The 96-vCPU quota also allows **up to 4 parallel 1-GPU A100 jobs** if you favour speed over cost. Run as independent loops (separate branches), optionally from one orchestrator holding both kube-contexts (next).

### Orchestrator deployment (VM or in-cluster pod) & parallel scaling

The "brain" (headless Claude Code — edits `candidate.py`, loops, keeps/discards) can run on a VM (diagram in §3) **or as a long-lived pod in the cluster** (a `Deployment`, or a `Job` with no deadline). **Pod form is recommended**: always-on ("keep running experiments" without logging into a VM and typing commands), keyless workload-identity credentials, nothing to babysit.
- **No docker-in-docker.** The orchestrator *creates Kubernetes Jobs* (an API call); it never builds or runs containers. So the agent pod needs only `kubectl`/a k8s client + the §7 RBAC (create Jobs + read pods/logs in `autoresearch`) attached via its ServiceAccount. No privileged pod, no docker socket. This is consistent with the hard rule that the agent never builds images — the only thing that would force DinD is exactly the thing we forbid.
- **Build-once agent image — lives in the `autoresearch` repo.** The orchestrator's image (Claude Code + kubectl + git + `program.md`/loop config) is defined by a `Dockerfile` in **this `autoresearch` repo** and built once by a human — same "can't rebuild itself" discipline as the eval image. Its **`Deployment` + ServiceAccount/RBAC/ResourceQuota/PVC live in bg-infra** (Flux, §7), so the running config is GitOps-managed. (Separation: *what the brain is* = autoresearch repo; *how it's run/permissioned* = bg-infra.)
- **On/off switch.** On italynorth (Flux-managed) start/stop the loop by setting the orchestrator `Deployment`'s **`replicas` 1↔0 in bg-infra** and letting Flux reconcile (a manual `kubectl scale` is reverted on the next reconcile → either commit the change or `flux suspend` first for an ad-hoc stop). Independently, the **GPU kill-switch** — `ResourceQuota requests.nvidia.com/gpu: 0` (§7) — halts *new Jobs* without touching the brain. On bg-gpu-de (no Flux) it's a plain `kubectl scale deploy/orchestrator --replicas=0/1`.
- **Placement.** Pin the agent pod to a **CPU node** (no GPU) and annotate it `karpenter.sh/do-not-disrupt` so consolidation (`nap-nodepools.yaml`) can't evict it mid-loop.

**Parallel scaling (what actually adds throughput — pod form alone does not):**
1. **More GPUs + parallel launch** — one orchestrator proposes *N* variants, fires *N* Jobs at once (up to the ResourceQuota), collects *N* scores, instead of the serial edit→run→read loop. Needs a merge policy for concurrent keeps (evaluate all candidates against a *fixed* current-best, then apply winners one at a time to avoid git races). v2+.
2. **Multiple independent loops** — separate branches/benchmarks/clusters (e.g. `autoresearch/dream-t4`, `autoresearch/sharik-a100`), each its own serial loop. Simplest safe parallelism. **Never run two brains on one branch** (git + keep/discard races).

## 7. Access and safety

- **Namespace:** create a dedicated **`autoresearch`** namespace (not `dagster-cloud`) so Jobs, quota, and RBAC are isolated from production runs — **in both clusters** (Q6; italynorth via Flux `INFRA/flux-infra-azure/autoresearch/namespace.yaml`, germanywestcentral via `kubectl apply`).
- **ServiceAccount + RBAC** (copy the minimal pattern from `clusters/prod-azure/.../bg-nextflow-k8s-executor-rbac.yaml`): `autoresearch-runner` SA with a Role scoped to **`autoresearch` namespace only**, allowing **Jobs** (`batch`, create/get/list/watch/delete), **pods/log, pods/status** (read), **ConfigMaps** (create/get/delete — the per‑run candidate delivery, §3) and **resourcequotas** (read) — and nothing else. No cluster‑role, no secrets, no other namespaces. (This matches the merged bg‑infra #307 `rbac.yaml`.) (The existing bg‑nextflow Role covers pods but not `batch/jobs` — a new Role is needed.) **Identity (Q10):** map the SA to a **new, dedicated Entra identity** created for autoresearch, *outside* `aks-bg-kubernetes-admins`, reused on both clusters.
- **ResourceQuota** (does **not** exist today — verified `verify:registry-rbac-killswitch` = partly; must create). New file `INFRA/flux-infra-azure/autoresearch/resourcequota.yaml`:
  ```yaml
  apiVersion: v1
  kind: ResourceQuota
  metadata: { name: autoresearch-quota, namespace: autoresearch }
  spec:
    hard:
      requests.nvidia.com/gpu: "1"   # v1: one GPU total → one job at a time
      requests.cpu: "16"
      requests.memory: "64Gi"
      pods: "8"
  ```
- **Read‑only data credentials.** Data PVC mounted `readOnly: true`; the one‑time S3 mirror uses a separate human/CI identity, never the agent's. Agent gets no S3 write, no Dagster, no production MLflow write.
- **The agent must never access:** evaluation/scorer/split code at runtime (baked into image), `test_labels`/locked test, ACR push, production MLflow experiments or Evidence streams, live Dagster assets, any namespace but `autoresearch`, any secret, the subscription/billing, or the cluster admin group.
- **Kill switch (all available today, verified):** (1) `kubectl -n autoresearch delete jobs --all`; (2) set `ResourceQuota requests.nvidia.com/gpu: "0"` → no new GPU jobs admit; (3) patch `gpu-t4` NodePool `limits.nvidia.com/gpu: "0"` (`nap-nodepools.yaml:197`) → no GPU nodes provision; (4) suspend the agent (stop the headless Claude Code process / its branch automation); (5) `kubectl delete ns autoresearch` (nuclear). Document (2) as the default soft stop. Pattern reference: `INFRA/scripts/aks-cutover-flip.sh:38-84`.

## 8. Tracking and memory

**Per‑run metadata (v1 → `score.json`; MLflow added later, Q5):** git commit (short), data snapshot id `(dream_version, split_seed, val_fraction)`, full resolved config, seed(s), primary Spearman‑r + secondary metrics, peak VRAM, wall‑clock train seconds, step count, param count, exit status. In v1 the frozen entrypoint writes this JSON to stdout + `/out/score.json`; the orchestrator appends the key fields to `results.tsv`. Once the MLflow server exists, the same dict is also logged to an agent-scoped experiment.

**Results log (agent‑owned, mirrors `REF/program.md:64-88`):** `results.tsv` with columns `commit  spearman  mem_gb  status  description` (status ∈ keep/discard/crash). Lives in the `autoresearch/<tag>` branch working tree but **gitignored** (untracked, like the reference), so it never enters a PR.

**Research notes between sessions:** `research_notes.md` **committed** to the agent branch — running log of ideas tried, near‑misses to revisit, and dead ends. This is the durable cross‑session memory (survives branch switches and context resets); `results.tsv` + git history complement it. (The locked‑test log is deliberately *not* here — see §4, human‑only.)

**Locked‑test log (human‑only):** v1 → `locked_test_results.tsv` outside the agent's reach (MLflow experiment `autoresearch-locked-test` once the server exists).

## 9. Draft agent instruction file (`program.md`)

Proposed `FOMO/program.md` (or `REF`‑style, adapted from `REF/program.md`):

```markdown
# FOMO autoresearch

Autonomously improve FOMO's DNA-sequence→expression model on the frozen DREAM
validation split. You edit one file, launch a fixed-budget train+score Job on the
AKS T4 cluster, read one score, and keep or discard the change.

## Setup
1. Branch: `git checkout -b autoresearch/<tag>` from master (tag = today, e.g. `mar5`).
2. Read for context (do NOT edit): README, src/fomo/models/candidate.py (your file),
   and this program.md. Everything else is off-limits.
3. Confirm the frozen image tag and the autoresearch namespace are reachable:
   `kubectl -n autoresearch get resourcequota` returns the quota.
4. Initialise results.tsv with the header row (leave untracked by git).
5. First run establishes the BASELINE — run candidate.py unmodified.

## What you CAN do
- Edit ONLY `src/fomo/models/candidate.py`: architecture, optimiser, loss, training
  step, hyperparameters, batch size, model size. All fair game.

## What you CANNOT do
- Edit anything else: the datamodule, the scorer, the split, the budget, the configs,
  the Job template, the image, dependencies. They are frozen in the image and ignored
  at runtime even if you change them on your branch.
- See or score the locked test set. You only ever see the val' Spearman-r.
- Add packages. Use only what is in the frozen image.

## Launch a run and read the result
1. Edit candidate.py; `git commit`.
2. Render + apply the Job for this commit and CAPTURE its generated name (the template uses
   `generateName:`, so you can't predict it):
   `JOB=$(sed "s/<commit>/$(git rev-parse --short HEAD)/g" job-template.yaml | kubectl -n autoresearch create -f - -o name)`
3. Wait for completion; stream logs to a file (do NOT flood context):
   `kubectl -n autoresearch wait --for=condition=complete "$JOB" --timeout=1300s`
   `kubectl -n autoresearch logs "$JOB" > run.log 2>&1`
4. Read the score: `grep '"spearman"' run.log` (the frozen entrypoint prints score.json).
5. Empty/failed grep = crash → `tail -n 50 run.log` for the trace.

## Keep / discard rule
- Primary metric: val' Spearman-r (HIGHER is better). Noise floor σ0 is measured once
  at setup (10 baseline seeds).
- Explore at 1 seed. If it doesn't beat the current best by ≥ σ0, DISCARD (git reset).
- Confirm a promising candidate at 3 seeds. KEEP only if mean beats current best by
  > 1.15·σ0. Else DISCARD.
- Simplicity tiebreak: equal-or-better with less code → keep; tiny gain with ugly
  complexity → discard.
- KEEP = advance the branch (keep the commit). DISCARD = `git reset --hard` to prior.

## Crashes, budget, stopping
- OOM/NaN/bug: if trivial (typo, missing import) fix and rerun; if the idea is broken,
  log status=crash in results.tsv and move on.
- Budget: each Job is capped at 20 min (activeDeadlineSeconds). If a Job hangs past
  that, it is killed — treat as crash/discard.
- Record every run in results.tsv. Keep research_notes.md updated with ideas + dead ends.
- Do NOT pause to ask whether to continue; loop until manually stopped. If out of ideas,
  re-read candidate.py, combine near-misses, try more radical architectures.

## Never do
- Never touch the scorer, split, test_labels, locked test, image, ACR, production MLflow,
  Dagster, S3 writes, other namespaces, secrets, or billing.
- Never report locked-test numbers (you never see them).
- Never open a PR to production — a human does that after review.
```

## 10. Phased rollout — two tracks

The rollout is deliberately split into **two versions with different purposes**. **v1** proves the loop *scientifically* using the throwaway, FOMO-coupled harness we already built (PRs below) — run it **once**, learn, keep the number. **v2** is the proper, reusable product — a standalone **`bg-autoresearch`** package (§13) that any model or statistical pipeline onboards through a published interface, with **zero autoresearch code in the model's repo**. We do **not** grow or refactor v1 into v2; v1 is superseded, and the clean PR happens at v2.

**v1 — run the current setup once (keep what's built; do not refactor).** DREAM + FOMO, **one T4, one job at a time**, overnight, agent edits `candidate.py` only, using exactly the harness that lives *inside* `bg-fomo` today. **Campaign goal: beat the baseline validation Spearman‑r by ≥ 5 %** (§4). Success = that single campaign runs unattended, keep/discard works against σ₀, nothing escapes the editable surface, the kill switch is verified, and we come away with a real improvement number. v1 can run with `bg-ai` #59 **built into the frozen image straight off its branch** — it need not merge to `bg-ai` master, because v2 replaces it. This is a one-shot proof, not a foundation to build on.
> **Status (2026-10-07):** plantbench **#60** reworked to the **train‑based** split (`train_validation_split` + `score_validation`) — `a5c0aacd` is pushed and **`plantbench 1.41.0rc1` is live on repoforge** (CI `build-and-publish` ✓; the red check is only the by‑design pre‑release merge‑guard). Two further #60 commits are staged (unpushed): a `score_validation` error‑hardening fix + a bump to **`1.41.0rc2`**, so the next push republishes the package with the fix. bg-ai **#59** (the FOMO harness) is rewired to call the new API; its `plantbench` pin → `==1.41.0rc2` + `uv lock` is gated on the rc2 push. bg-infra **#307 merged** and **Flux bootstrapped** on italynorth `bg-kubernetes`; the orchestrator Deployment is stacked in **#313** (`replicas: 0`). Remaining to run v1: push #60 (republishes rc2) → FOMO pin `==1.41.0rc2` + relock + commit #59; build+lock the eval image; mirror the DREAM snapshot; merge #313; and the σ₀ noise‑floor run.

**Gate to widen (all must hold):** eval image built + tag made immutable; agent confirmed to have no AcrPush and no write to data/locked test; σ₀ measured and the 2σ rule wired in; one‑time S3→Azure mirror done (egress paid once); `ResourceQuota` + `autoresearch-runner` RBAC applied; locked‑test cadence producing human‑only reports; kill switch tested end‑to‑end.

**v2 — `bg-autoresearch`: the model-agnostic refactor (the proper PR).** Everything autoresearch moves *out* of `bg-fomo` into a standalone **`bg-autoresearch`** package (full design in §13). The model is consumed as an installed **wheel** and onboarded through a published interface — *be scored by the same `bg-ai/libs/plantbench` metrics* + *expose a standard auto-run adapter* — so FOMO, FRI, future models, and non-DL/statistical pipelines plug in **without any autoresearch code landing in their repos**. This is the version we open a clean PR for.

**v2 expansion (scale + rigor, riding on `bg-autoresearch`).** Once the package exists, move to the real scientific target — **`sharik_expression_prediction`** (tissue→gene; the cell/tissue-context conditioning FOMO actually cares about) — and/or add `g1001_gene_expression_prediction` **with mandatory `get_stratification_by_train_overlap()`** (real accessions → leakage). The benchmark-owned split already exists in `plantbench` for **both DREAM and Sharik** (PR #60); the main wiring left is a Sharik adapter/config — note Sharik's defaults omit Spearman-r and its per-gene (axis-0) score degenerates on a small pair-based `validation` subset, so it must pass Spearman-r via `custom_metrics` and steer on the per-tissue (axis-1) metric. Onboard a **second model loop** (**bg-fri** ↔ `protein_function_annotation`) to prove the interface is really model-agnostic. Raise quota to 2–4 T4s for parallel candidates, or use the A100 cluster for heavier context. Widen the editable surface cautiously (e.g., allow an arch YAML alongside `candidate.py`).

**v3 (productionise the output).** Parallel Optuna‑style search; multiple benchmarks/models (add `bg-fri` ↔ `protein_function`); automatic drafting of a **human‑reviewed PR** for a kept improvement that also clears the locked test. Org API key replaces the personal subscription for the headless agent.

## 11. Risks and mitigations

| Risk | Specific to this data | Mitigation |
|---|---|---|
| **Split leakage** | g1001/ms/sharik default path leaks across accession/batch/ortholog/LD (verified) | v1 uses DREAM (synthetic → no leakage). For v2 benchmarks, **require** the relevant stratification; add ortholog/accession grouping before enabling. |
| **Benchmark overfitting** | agent optimises val' Spearman repeatedly | Locked test (official DREAM test) checked rarely, human‑only; stop if val'↑ while locked‑test flat/↓; noise‑floor gate prevents chasing seed noise. |
| **Eval tampering** | agent could edit scorer/budget on its branch | Scorer/split/budget baked into an immutable ACR image, imported from the installed package; agent has no AcrPush. Runtime ignores branch edits to those files. |
| **T4 / bf16 misuse** | bf16 option exists, unsupported on T4 | Pin `16-mixed` in the T4 frozen config; **keep** `bf16-mixed` for A100 but add a runtime assert rejecting it on T4 (§3‑T5); the per-cluster config guards it. |
| **Cross‑cloud egress runaway** | per‑pod S3 pulls from eu‑west‑2 to Azure | One‑time mirror to Azure PVC/Blob; Jobs read local, read‑only. |
| **Cost runaway** | shared 8‑T4 pool, NC64 ~$5/hr | `ResourceQuota gpu:1` (v1); `activeDeadlineSeconds`; kill switch; Azure budget alert already configured (`INFRA/terraform/azure/variables.tf`). |
| **Nondeterminism inflates noise** | no global seed in eval; some np.shuffle unseeded | Seed torch+numpy in the entrypoint; measure σ₀ empirically and gate on it rather than assuming determinism. |
| **Escaping editable surface** | agent has shell + kubectl | RBAC scoped to one namespace (jobs+logs only); read‑only data; no secrets; no push; dedicated namespace. |
| **Contaminating production** | shared MLflow/Dagster | v1 writes **no MLflow at all** (`score.json` + `results.tsv`); later, an agent-scoped experiment only; no Dagster, no S3 write, no Evidence. **PR‑only is mechanical**: the agent works on `autoresearch/<tag>` branches, `master` has branch protection requiring human review, and the agent identity holds no merge / deploy / AcrPush / prod credentials — so it *cannot* ship, only propose. |

## 12. Open questions — status (updated 2026-10-05)

**Resolved this round (your answers + live checks):**
- **Q1 (data sizes):** measured via the `standard` AWS profile — DREAM s2e **~0.59 GB**, STARR-seq **~33 MB**, multispecies train **~18.4 GB**, 1001G raw **~1.1 GB** (§5). PVC: 10 GB for v1, ~30 GB for v2.
- **Q2 (image build):** you'll build it — concrete steps in the Appendix → *Frozen image build*.
- **Q3 (metric):** Spearman‑r for v1; revisit after colleague review.
- **Q4 (val'/split):** decided — the **benchmark owns the split** (`plantbench` `train_validation_split`): deterministically carve a decile‑stratified `validation` subset (seed 42, val_fraction 0.2) out of DREAM's **`train`** pairs, leaving a disjoint `train` remainder; the official `test` set is left whole (§3‑T1). **Updated per Paride's review** (validation must come from train, never the test set). **Goes up as the `bg-ai` plantbench PR #60 for colleague sign‑off before FOMO's pin is bumped and the image is frozen** (your ask).
- **Q5 (MLflow):** v1 ships **without** MLflow (`score.json` + `results.tsv`); you add the server in parallel.
- **Q6 (namespace):** dedicated `autoresearch` namespace in **both** clusters.
- **Q7 (budget):** `budget_seconds` is a **per-cluster config knob** (T4 default 600 s; A100 set after its baseline).
- **Q8 (egress):** no constraints → one-time **S3→Azure Blob** copy, one per region.
- **Q9 (candidate delivery):** **per-run ConfigMap** mounted read-only into the Job (keeps the pod credential-less — no in-cluster git token); eval imported from the installed frozen package (§3).
- **Q10 (identity):** create a **separate, dedicated Entra identity** (outside `aks-bg-kubernetes-admins`), reused on both clusters.
- **Q11 (A100 shape):** cluster **now created** — `bg-gpu-de` / RG `bg-gpu-de-rg`, germanywestcentral, k8s 1.35; `a100` pool live = `NC24ads_A100_v4` (1× A100 80 GB), label `workload=gpu-a100`, taint `sku=gpu`, scale-to-zero `min0/max1` (raise max to 4 for the full 96-vCPU quota); geo-replicated ACR pull-only (§6).
- **Q12 (Germany mirror):** yes — mirror the frozen snapshot to germanywestcentral.

**Still open (need you / colleagues):**
- **MLflow target:** when your server is up, confirm the agent-scoped tracking URI (never prod).
- **Colleague review (via PR):** the split method + params (Q4) + metric (Q3) go up as the **`bg-ai` plantbench PR #60** (`train_validation_split` + `score_validation` + their tests); colleagues sign off there **before FOMO's `plantbench` pin is bumped to the published version and the image is frozen**, and before the first *real* scientific loop (sharik/context).
- **A100 setup (remaining):** cluster `bg-gpu-de` is up and its `a100` pool label/taint are confirmed. Still to do — deploy the `autoresearch` namespace + SA + RBAC + ResourceQuota via `kubectl` on `bg-gpu-de`; mirror the frozen snapshot to a germanywestcentral Blob; and (for parallelism) raise the `a100` pool `max_count` to 4.

---

# Step 3 — v2 design (model-agnostic)

## 13. `bg-autoresearch` — the model-agnostic package and onboarding interface

**Why.** Two asks, one design: (a) *no autoresearch code should land in a model's repo* (keep it out of `bg-fomo`), and (b) *one harness drives FOMO, FRI, future models, and non-DL / statistical pipelines*. This is cheap because the seam already exists — PlantBench is model-agnostic (it scores an `AnnData` submission, never a model object), and the two FOMO surfaces the loop actually needs — `fomo.utils.plantbench.submit_predictions` (a module-level, model-class-free function) and `fomo.data.datamodule.FomoDataModule` — are already importable from the installed wheel. So v2 is mostly a **relocation (a net deletion from `bg-fomo`)**, not new logic.

**The package.** A standalone **`bg-autoresearch`** (its own repo, or `src/bg_autoresearch/` in this one), published to repoforge, that owns the entire model-agnostic core: candidate load-by-path, the wall-clock budget, consuming the benchmark-owned split, calling `evaluate()`, the scorer, `score.json`, crash capture, and the orchestrator loop. Each frozen eval image is then just `FROM <model wheel> + bg-autoresearch` (one image per model, because of torch/lightning version skew between models).

**The onboarding interface — what a model or pipeline must adopt (and *only* this):**
1. **Be scored by the same metrics as `bg-ai/libs/plantbench`.** The model must emit its predictions as a PlantBench `AnnData` submission — `obs` = source entities, `var` = target entities, `X` = score matrix — that the target benchmark's `validate_data()` accepts, and be scored through the **same** `benchmark.evaluate()` path the leaderboard uses. No bespoke metric, ever. *A statistical / non-DL pipeline qualifies with no model at all* — the existing baselines under `bg-ai/libs/plantbench/baselines/{expression,feature,sequence}_based` already produce submissions through exactly this interface, which is the proof that "onboard a statistical pipeline" is a real, supported path.
2. **Expose a standard auto-run adapter.** A small `ModelAdapter` that **lives in `bg-autoresearch`, not in the model repo**, carrying declarative scoring metadata (benchmark name/version, `task_type`, primary-metric token, metric axis, higher-is-better, precision) and one method:
   `fit_and_submit(candidate_path, benchmark, validation_strat, *, budget_seconds, seed, precision, out_dir) -> (submission_name, submission_date)`
   — it trains the candidate under the wall-clock budget and registers a submission via `benchmark.submit()`. *How* it trains (Lightning + `Timer`, sklearn-to-deadline, API-spend budget) is entirely the adapter's business; the harness never sees a torch module. This is the "way to automatically run those metrics" made concrete.

**Expose the model source to the headless agent — yes.** The brain has to *understand* the model to edit `candidate.py` well, so the orchestrator gives it the model's **source tree, read-only, purely for comprehension** (today it already checks out the `bg-ai` branch and reads under `ml/bg-fomo`; in v2 it clones/mounts the onboarded model's repo read-only). Crucial safety nuance: this is **separate from the frozen runtime**. The eval image imports the model from the **pinned wheel**, so any edit the agent makes to that source on its branch is **ignored at run time** — the only thing that reaches the Job is `candidate.py`, delivered per-run by ConfigMap and loaded by path. Read to learn; the editable surface stays exactly one file.

**What moves out of `bg-fomo` (net deletion), and the three caveats.** scorer, entrypoint, candidate seed, `Dockerfile.autoresearch`, and `program.md` move to `bg-autoresearch`; the `pyproject.toml` plantbench pin reverts; the only genuinely new code is the `FomoAdapter`, which fills the `_train_and_submit` stub #59 already defers (same work, now harness-side). Caveats, all verified against source and all small:
- **(a) scorer generalization.** The scorer is Spearman-hardcoded; generalize `extract_spearman` → `extract_primary(metrics, stratum, metric_token, axis, higher_is_better)` before a classification model (FRI) can be scored.
- **(b) FRI wall-clock fairness.** FRI's trainer hardcodes callbacks / `max_epochs` with no `Timer` hook, so a *fair wall-clock* FRI budget needs either a harness-side FRI Trainer or a one-line **generic** `callbacks=` hook in FRI. FRI's day-1 adapter is otherwise epoch-bounded (acceptable, but not wall-clock-comparable to FOMO).
- **(c) de-facto API.** `FomoDataModule`'s kwargs are a de-facto (not formally blessed) public surface → **pin the fomo wheel** in the frozen image + a **build-time smoke test** that constructs it, so a wheel upgrade can't break the adapter silently.
None of these touch FOMO's model logic.

**Shared dependency (both tracks).** v1 and v2 both require the benchmark‑owned split. ✅ **Implemented** in **bg-ai PR #60** (`feat/plantbench-test-validation-split`): `DeterministicTrainValidationSplitMixin.train_validation_split(*, val_fraction=0.2, seed=42, n_bins=10) -> {"train", "validation"}` + `score_validation(predictions)` in `bg-ai/libs/plantbench/src/plantbench/benchmarks/mixins.py`, carving a decile‑stratified `validation` subset out of the benchmark's **TRAIN** pairs (the official test set is left whole) and scoring validation predictions against the train labels through the benchmark's own preprocessing + default metrics (keys `validation.<Metric>.axis<n>`). **DREAM (`DREAMSequence2ExpressionPrediction`) and Sharik (`SharikRandomSplit`) already mix it in.** (An earlier design partitioned the **test** set into `{validation, locked_test}`; Paride's review replaced it with this train‑based split so the test set stays comparable across submissions. The canonical plantbench is `bg-ai/libs/plantbench`, published to repoforge — the standalone `../PlantBench` repo is stale, ignore it.) Publishing state: `a5c0aacd` is pushed and **`1.41.0rc1` is live**; the staged `score_validation` error‑hardening + bump to **`1.41.0rc2`** republish the package with the fix on the next push. The gate is the ordinary one: **push #60 (publishes `1.41.0rc2`) → FOMO pins `==1.41.0rc2` + relocks** before either track can score (the entrypoint calls `train_validation_split` + `score_validation`).

---

### Appendix — new files proposed (path → purpose)
**v1 layout (below).** This Appendix lists the **v1, in-`bg-fomo`** file placement. In v2 (§13) these autoresearch files relocate out of `bg-fomo` into the standalone `bg-autoresearch` package, and the model is consumed as a wheel.
- `FOMO/src/fomo/models/candidate.py` → the single editable model (agent edits).
- `FOMO/src/fomo/autoresearch/scorer.py` → thin, pure extractor of the `validation` Spearman‑r (+ secondary scalars) out of a `plantbench` `evaluate()` result.
- Split: **benchmark‑owned**, in `plantbench` (`train_validation_split` + `score_validation`, bg-ai PR #60) — no split_manifest.parquet / SPLIT.md / make_autoresearch_split.py in FOMO (removed).
- `FOMO/src/workflow/autoresearch_run.py` → frozen entrypoint: benchmark split + `evaluate()` on `validation`, wall‑clock budget, T4 precision guard.
- `FOMO/src/workflow/configs/experiments/autoresearch_dream.yaml` → frozen experiment config.
- `FOMO/Dockerfile.autoresearch` → frozen eval+train image. Decision: **new file, not the existing `FOMO/Dockerfile`** (that one's base is an AWS‑ECR SageMaker image, wrong for AKS). Use a standard CUDA‑12.4 PyTorch base; pin `plantbench` via `BGAI/uv.lock`. Built + pushed + tag‑locked once to ACR by a human admin (§3‑T6).
- `FOMO/program.md` → agent instruction file (§9).
- `INFRA/flux-infra-azure/autoresearch/{namespace,resourcequota,runner-sa,runner-rbac,job-template,orchestrator-deployment}.yaml` → isolated namespace, quota, locked‑down SA+Role, Job template, and the orchestrator `Deployment` (Flux‑managed; `replicas` is the on/off switch).
- `autoresearch/` repo (this workspace) → the orchestrator "brain" image: `Dockerfile` (Claude Code + kubectl + git) + loop entrypoint + `program.md`; built once by a human (keeps the nanoGPT‑style `prepare.py`/`train.py`/`analysis.ipynb` as the reference harness we model).
- `results.tsv`, `research_notes.md` (agent VM, untracked) → run log + cross‑session memory.
- `locked_test_results.tsv` / MLflow `autoresearch-locked-test` (human‑only) → locked‑test cadence output.

---

### Appendix — Frozen image build (Q2: you build it)

One immutable image = the FOMO package + the frozen harness (T1–T4), which the clusters **pull** (never the agent). Build once per eval definition; rebuild only to change the frozen eval (→ a new tag). A human/CI with AcrPush does this; the agent never does.

**1. Dockerfile** `FOMO/Dockerfile.autoresearch` (sketch — standard CUDA base, NOT the SageMaker/ECR base; verify the exact base tag):
```dockerfile
# CUDA 12.x base covering T4 (sm_75) and A100 (sm_80) — pick one:
FROM pytorch/pytorch:2.6.0-cuda12.4-cudnn9-runtime
# or: FROM nvcr.io/nvidia/pytorch:24.10-py3
WORKDIR /app
RUN pip install uv
COPY pyproject.toml uv.lock README.md ./
COPY src/ ./src/
# installs bg-fomo + its PINNED plantbench from uv.lock → the frozen eval.
# FORGE_API_KEY as a BuildKit *secret* (not an ARG) so it never lands in a layer:
RUN --mount=type=secret,id=forge \
    UV_INDEX_REPOFORGE_USERNAME=anystring \
    UV_INDEX_REPOFORGE_PASSWORD="$(cat /run/secrets/forge)" \
    uv pip install --system .
ENTRYPOINT ["autoresearch-run"]      # the T3 console script
```

**2. Build + push** (you/CI, with AcrPush — never the agent):
```bash
export FORGE_API_KEY=...             # short-lived repoforge key
DOCKER_BUILDKIT=1 docker build --secret id=forge,env=FORGE_API_KEY \
  -t biographicaregistry.azurecr.io/autoresearch-fomo:dream-v1 \
  -f FOMO/Dockerfile.autoresearch FOMO/
az acr login -n biographicaregistry
docker push biographicaregistry.azurecr.io/autoresearch-fomo:dream-v1
```

**3. Lock the tag immutable** (so even an AcrPush identity can't overwrite it) and record the digest (Jobs pull by `@sha256:`):
```bash
az acr repository update -n biographicaregistry \
  --image autoresearch-fomo:dream-v1 --write-enabled false
az acr manifest show -n biographicaregistry \
  -r autoresearch-fomo -t dream-v1 --query digest -o tsv
```

**4. A100 variant:** same Dockerfile, sibling tag `autoresearch-fomo-a100:dream-v1`, plus a frozen config with `precision: bf16-mixed`. ACR Premium geo-replication (in `azure-gpu-de/acr.tf`) serves it locally in germanywestcentral.

**5. Smoke test** before wiring the loop: run one Job that trains the baseline `candidate.py` for a short budget and prints `score.json` — proves the frozen path end-to-end (mirror `azure-gpu-de/manifests/a100-smoke-test.yaml`, swapping in the ACR image to also exercise AcrPull).
