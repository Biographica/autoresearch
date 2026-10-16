# v2 design note — parallel candidate eval + compute cap

Status: **spec only, not built** (decision 2026-10-16). v1 proved the loop end-to-end
(serial keep/discard, one eval Job at a time). Parallel eval + a GPU budget are a natural
feature of the standalone **`libs/autoresearch`** (v2) package and are specced here so the
work is scoped when v2 starts. The external *token* kill-switch (v1) is separate and
already built (bg-infra PR #335).

## 1. Compute cap (two independent ceilings — use both)

- **ResourceQuota `requests/limits.nvidia.com/gpu: N`** (`resourcequota.yaml`, currently
  `1`) — the cheapest hard ceiling on concurrent eval Jobs. The GPU analogue of the token
  cap. A soft kill is `gpu: 0` (new Jobs blocked, in-flight finish) — the external
  kill-switch already does this on a token trip (`ZERO_GPU_QUOTA`).
- **Nodepool `max-count`** on `gpu-t4` (cap 8, **shared with Dagster `fri_finetuning`**) —
  the physical ceiling. Keep headroom for Dagster: `N ≤ 4` is safe; up to ~6 needs
  coordination. For a bigger isolated sweep, the germanywestcentral A100 cluster
  (`bg-gpu-de`, scale-to-zero, bf16, its own quota) is the alternative.

A GPU-hours budget (analogue of the token cap) could be enforced by a sibling CronJob
summing eval-Job GPU-seconds (from Job records / node metrics) and zeroing the quota at a
cap — but quota + nodepool max are usually enough.

## 2. Parallel candidate eval

**Already unblocked on storage.** The RWX data PVC `autoresearch-data-rwx` (azurefile-nfs,
validated at 6 pods across 2 nodes) removes the RWO Multi-Attach limit, so N eval Jobs can
run on N nodes concurrently. What's missing is the *brain logic*.

**The change is in the brain, not the eval.** v1's loop is strictly serial: one
`candidate.py` → one Job → wait → keep/discard. Parallel needs a **batched round**:

1. Per round, generate **K** candidate variants (K distinct `candidate.py` commits/
   ConfigMaps + K Jobs launched together).
2. `kubectl wait` on all K; read K `score.json`s.
3. Keep the best **vs the incumbent and vs each other**, using the same `1.15·σ₀` margin;
   multi-seed-confirm the round winner before it becomes the new incumbent.
4. Raise the quota first: e.g. `gpu: 4, cpu: 48, memory: 192Gi, pods: 16` (keep Dagster
   headroom).

**Keep "one brain per branch."** Parallelism lives in the *eval fan-out*, not in running
multiple brains — two brains on one branch race on git + keep/discard. The branch stays
single-writer; only the Jobs fan out.

### Tradeoffs
- K× GPU cost per round, but ~K× faster exploration (and the σ₀ noise floor is better
  sampled per round).
- Keep/discard becomes a *batch* decision (incumbent vs a cohort) rather than pairwise —
  a small bandit/evolutionary step. More moving parts to monitor (K Jobs, K score files,
  partial-failure handling if a Job dies).
- Natural fit for the `libs/autoresearch` **`ModelAdapter`** boundary: the adapter owns
  `fit_and_submit(...)`; a `BatchScheduler` owns launching/collecting K of them.

## 3. Where this lands
Implement in the v2 standalone `libs/autoresearch` package (plan §13), which relocates the
harness out of `ml/bg-fomo` and consumes the model as a wheel. The parallel-eval scheduler
+ the batched keep/discard are the package's scheduler layer; the per-hardware precision /
quota rules carry over unchanged.
