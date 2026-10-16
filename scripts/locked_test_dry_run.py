#!/usr/bin/env python3
# ============================================================================
#  locked_test_dry_run.py
#  HUMAN-ONLY "locked test" dry run against the BASELINE model on the OFFICIAL
#  DREAM sequence->expression test set.
#
#  Purpose: prove the human-scoring path works and is ISOLATED from the agent
#  loop. It trains the baseline candidate on TRAIN, predicts the OFFICIAL TEST
#  pairs (incl. reference sequences), submits + evaluates through PlantBench's
#  stable public API, and records the Spearman-r in a HUMAN-OWNED local file
#  (locked_test_results.tsv) -- never in the agent's ephemeral score.json.
#
#  WHY the agent never sees this: the loop scores a TRAIN-derived `validation`
#  subset via benchmark.score_validation() and writes /out/score.json on an
#  emptyDir (ephemeral) in a credential-less pod whose PVC has ONLY the train
#  asset. This script is the opposite: run LOCALLY, with AWS creds, it pulls the
#  TEST asset from S3 and uses benchmark.submit()/benchmark.evaluate().
#
#  ------------------------------------------------------------------------
#  PREREQUISITES
#  ------------------------------------------------------------------------
#  * Run from the bg-ai checkout on branch feat/autoresearch-harness:
#      cd ~/Documents/projects/bio_git/bg-ai/ml/bg-fomo
#  * A Python env with the FOMO harness + its PINNED plantbench installed:
#      uv sync            # installs plantbench==1.41.0rc3, fomo, torch, lightning...
#    then run this script through that env:
#      uv run python /path/to/locked_test_dry_run.py
#    (plantbench 1.41.0rc3 has the newer score_validation()/train_validation_split()
#     the loop uses; this script does NOT need them -- it uses only the stable
#     submit()/evaluate() API present in every plantbench. See NOTE 1 below.)
#  * AWS creds with READ access to s3://bg-data-prd (benchmark config, train+TEST
#    assets). NO submission-bucket WRITE needed: this script uses local stores
#    (submission_store="local"/result_store="local"), so nothing is PutObject'd to
#    the prod s3://plantbench/bg-submissions bucket. (A StandardUser SSO role has the
#    read access but not that write — which is correct; see NOTE 2.)
#      aws sso login            # or export AWS_PROFILE / AWS_ACCESS_KEY_ID ...
#    Sanity-check:  aws sts get-caller-identity
#  * A LOCAL plantbench cache dir you control (so test assets are not written to a
#    shared location). Set BEFORE importing plantbench:
#      export PLANTBENCH_HOME="$HOME/.plantbench-lockedtest"
#  * GPU strongly recommended (the baseline is a small CNN; CPU works but is slow).
#
#  ------------------------------------------------------------------------
#  HOW TO RUN
#  ------------------------------------------------------------------------
#      export PLANTBENCH_HOME="$HOME/.plantbench-lockedtest"
#      aws sso login
#      cd ~/Documents/projects/bio_git/bg-ai/ml/bg-fomo
#      uv run python locked_test_dry_run.py \
#          --budget-seconds 600 \
#          --results-file "$HOME/locked_test_results.tsv"
#
#  The script prints the official-test Spearman-r and the ABSOLUTE PATH where it
#  was recorded, and asserts that path is NOT inside any agent workdir.
# ============================================================================
#
#  NOTE 1 (API provenance -- verified against branch feat/autoresearch-harness):
#    * Benchmark factory:            plantbench.benchmarks.Benchmark(name, split, task_type).load(version)
#                                    (libs/plantbench/src/plantbench/benchmarks/__init__.py)
#    * DREAM s2e benchmark class:    DREAMSequence2ExpressionPrediction, registered as
#                                    "dream_sequence2expression_prediction", version "2025-06-02_14-16-47"
#                                    source_column_name="dataset", target_column_name="sequence_id",
#                                    label_column_name="expression"
#                                    (libs/plantbench/src/plantbench/benchmarks/sequence_to_expression.py)
#      Its preprocessing_fn == labels_preprocess_fn == compute_expression_difference
#      (reference-subtraction via ref_seq_id); evaluate() applies these AUTOMATICALLY.
#    * submit(data: AnnData, submission_name: str, metadata=None) -> date_str
#    * evaluate(submission_name_date_pairs: tuple[str,str] | list[tuple], ...,
#               result_store set at load()) -> EvaluationResults
#      (both in libs/plantbench/src/plantbench/benchmarks/base.py)
#      => the runbook sketch `benchmark.submit(preds, name)` then
#         `benchmark.evaluate((name, date))` is CORRECT (submit's positional order
#         is (data, submission_name); evaluate takes a (name, date) tuple).
#    * Submission AnnData is built the same way FOMO's production path builds it
#      (fomo/utils/plantbench.py::submit_predictions + plantbench.utils.create_anndata_obj):
#      obs_names = source (dataset), var_names = target (sequence_id), X = predictions,
#      covering EVERY (dataset, sequence_id) pair in the test split (NaN->0.0 fill).
#
#  NOTE 2 (stores -> isolation): plantbench's DEFAULTS are MLflow (result_store,
#    base.py:169) and S3SubmissionStore -> s3://plantbench/bg-submissions
#    (submission_store, base.py:155). That S3 path is the CI/official submission flow,
#    NOT a local dry run; writing there needs prod-write creds a StandardUser role
#    (correctly) lacks. So we load BOTH stores local:
#      result_store="local"     -> LocalResultStore writes metrics.json under
#                                  $PLANTBENCH_HOME/<benchmark>__v_<version>/results/...
#      submission_store="local" -> LocalSubmissionStore writes the submission .h5ad
#                                  under $PLANTBENCH_HOME (no bucket PutObject at all)
#    evaluate() reads the submission back from the SAME store (base.py:679), so
#    local-only is self-consistent. We read the Spearman-r out of the local result
#    store and ALSO append a one-line row to a human-only locked_test_results.tsv.
#    The agent loop, by contrast, never calls evaluate() on the test set.
#    (To stage into a scratch bucket you CAN write instead of pure-local, keep
#    submission_store="s3" and `export PLANTBENCH_S3_SUBMISSIONS=s3://<scratch>/...`.)
#
#  NOTE 3 (baseline artifact plug-in point): v1 has NO cached baseline checkpoint
#    (the Job runs with enable_checkpointing=False). This script therefore TRAINS
#    the baseline fresh under the same wall-clock budget as the loop, exactly
#    mirroring workflow/autoresearch_run.py::_train_and_predict. If/when a cached
#    baseline checkpoint exists, load it where marked "PLUG IN CACHED BASELINE".
# ============================================================================

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import timedelta
from pathlib import Path


def _train_and_predict_official_test(model, trainer, benchmark, budget_seconds):
    """Train the baseline on TRAIN and predict EVERY official-TEST (dataset, seq) pair.

    Mirrors workflow/autoresearch_run.py::_train_and_predict, but predicts the
    OFFICIAL TEST split instead of the TRAIN-derived `validation` subset. Returns a
    long-form DataFrame [dataset, sequence_id, predictions] covering all test pairs
    (incl. reference sequences), which is what evaluate()'s reference-subtraction
    preprocessing needs.
    """
    import numpy as np
    import pandas as pd
    import torch
    from torch.utils.data import DataLoader

    from fomo.data.collator import Collator
    from fomo.data.dataset import BaseDataset, DatasetConfig
    from fomo.schema.enums import IO

    s_col = benchmark.source_column_name   # "dataset"
    t_col = benchmark.target_column_name   # "sequence_id"
    l_col = benchmark.label_column_name    # "expression"
    seq_col = IO.S2I.value                 # "seq2int" (pre-encoded, length 110)
    pred_col = IO.PRED.value               # "predictions"

    # ---- TRAIN rows: pre-encoded seq + label (read from local cache / S3) --------
    train_paths = benchmark.get_data(train=benchmark.files["train"])["train"]
    train_df = pd.concat(
        [pd.read_parquet(p, columns=[s_col, t_col, seq_col, l_col])
         for p in train_paths.values()],
        ignore_index=True,
    )
    train_df = (
        train_df.sort_values([s_col, t_col, l_col], kind="stable")
        .drop_duplicates(subset=[s_col, t_col], keep="first")
        .reset_index(drop=True)
    )
    train_df = train_df[~pd.isna(train_df[l_col])].reset_index(drop=True)
    if train_df.empty:
        raise RuntimeError("no TRAIN rows after de-dup; train asset missing/empty")

    # Z-score TRAIN target for optimisation stability only (Spearman-r is rank-based).
    sigma = float(train_df[l_col].std())
    if sigma and np.isfinite(sigma):
        train_df[l_col] = (train_df[l_col] - float(train_df[l_col].mean())) / sigma

    # ---- OFFICIAL TEST pairs: download the TEST asset from S3 and read ALL rows ---
    # get_data(test=True) returns the single test-split parquet path. This is the
    # step that requires AWS creds and pulls the asset the agent pod never has.
    test_path = benchmark.get_data(test=True)["test"]
    # Read every (dataset, sequence_id) pair + its pre-encoded sequence. One row per
    # pair; the test split already includes the reference sequences as their own rows
    # (evaluate()'s compute_expression_difference looks them up via ref_seq_id).
    test_df = pd.read_parquet(test_path, columns=[s_col, t_col, seq_col])
    test_df = test_df.drop_duplicates(subset=[s_col, t_col]).reset_index(drop=True)
    if test_df.empty:
        raise RuntimeError("no TEST rows; test asset missing/empty")

    collator = Collator(jagged_input_mode="pad", pad_length=110)  # DREAM seqs are 110

    def _loader(df, *, train):
        ds = BaseDataset.from_config(
            DatasetConfig(data=df, input_col=seq_col,
                          target_col=(l_col if train else None)),
            "pandas",
        )
        default = 128 if train else 512
        attr = "train_batch_size" if train else "predict_batch_size"
        workers = 0 if train else int(os.environ.get("AR_PREDICT_WORKERS", "4"))
        return DataLoader(
            ds,
            batch_size=int(getattr(model, attr, default)),
            shuffle=train,
            collate_fn=collator,
            num_workers=workers,
            drop_last=train,  # predict keeps EVERY row in order
        )

    # ----- PLUG IN CACHED BASELINE (if one ever exists) -----------------------
    # If a frozen baseline checkpoint is available, replace the fit() call below
    # with:   model.load_state_dict(torch.load(<ckpt>)["state_dict"]); model.eval()
    # v1 has none, so we train fresh under the same wall-clock budget as the loop.
    trainer.fit(model, train_dataloaders=_loader(train_df, train=True))

    batch_preds = trainer.predict(model, dataloaders=_loader(test_df, train=False))
    preds = (
        torch.cat([torch.as_tensor(p).reshape(-1) for p in batch_preds])
        .float().cpu().numpy()
    )
    if len(preds) != len(test_df):
        raise RuntimeError(f"pred count {len(preds)} != test rows {len(test_df)}")

    return pd.DataFrame({
        s_col: test_df[s_col].to_numpy(),
        t_col: test_df[t_col].to_numpy(),
        pred_col: preds,
    })


def main() -> int:
    p = argparse.ArgumentParser(description="Human-only DREAM locked-test dry run (baseline).")
    p.add_argument("--candidate-path",
                   default="src/fomo/models/candidate.py",
                   help="Path to the BASELINE candidate.py (unmodified baseline).")
    p.add_argument("--benchmark", default="dream_sequence2expression_prediction")
    p.add_argument("--task-type", default="regression")
    p.add_argument("--benchmark-version", default="2025-06-02_14-16-47")
    p.add_argument("--budget-seconds", type=int, default=600)
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--submission-name", default="baseline_locked_test_dryrun")
    p.add_argument("--results-file",
                   default=os.path.expanduser("~/locked_test_results.tsv"),
                   help="HUMAN-ONLY results file (NOT the agent's score.json).")
    p.add_argument("--precision", default="16-mixed")
    args = p.parse_args()

    # Fail loudly if PLANTBENCH_HOME is unset -- we must NOT fall back to the shared
    # ~/.plantbench default for a human locked-test.
    if not os.environ.get("PLANTBENCH_HOME"):
        print("ERROR: set PLANTBENCH_HOME to a local cache dir you control, e.g.\n"
              "  export PLANTBENCH_HOME=\"$HOME/.plantbench-lockedtest\"", file=sys.stderr)
        return 2

    import importlib.util

    import lightning.pytorch as pl
    from lightning.pytorch.callbacks import Timer

    from plantbench.benchmarks import Benchmark

    # ---- AWS creds preflight (the agent pod has none; the human must) -----------
    try:
        import boto3
        boto3.client("sts").get_caller_identity()
    except Exception as e:  # noqa: BLE001
        print(f"ERROR: AWS creds not usable ({type(e).__name__}: {e}). "
              f"Run `aws sso login` / set AWS_PROFILE and retry.", file=sys.stderr)
        return 2

    # ---- Load the BASELINE candidate class by path (NOT the installed package) --
    cand_path = Path(args.candidate_path).expanduser().resolve()
    if not cand_path.is_file():
        print(f"ERROR: candidate not found: {cand_path}", file=sys.stderr)
        return 2
    spec = importlib.util.spec_from_file_location("locked_test_candidate", str(cand_path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    CandidateModel = getattr(mod, "CandidateModel")

    pl.seed_everything(args.seed, workers=True)

    # ---- Load the benchmark with LOCAL (human-owned) stores ---------------------
    # Both stores local so a dry run touches NO bucket (prod or scratch):
    #   result_store="local"     => LocalResultStore writes metrics.json under
    #                               $PLANTBENCH_HOME, NOT the shared MLflow tracker.
    #   submission_store="local" => LocalSubmissionStore writes the submission .h5ad
    #                               under $PLANTBENCH_HOME, NOT s3://plantbench/bg-submissions.
    # The DEFAULT submission_store is S3 (base.py:155) which PutObjects to the PROD
    # bucket bg-submissions — that is the CI/official submission path, NOT a local
    # dry run, and a StandardUser role (correctly) can't write there. evaluate()
    # fetches the submission back from this SAME store (base.py:679), so local-only
    # is self-consistent. To instead stage into a scratch bucket you can write,
    # drop these and `export PLANTBENCH_S3_SUBMISSIONS=s3://<your-scratch>/...`.
    benchmark = Benchmark(args.benchmark, task_type=args.task_type).load(
        version=args.benchmark_version,
        result_store="local",
        submission_store="local",
    )

    # ---- Train baseline on TRAIN, predict the OFFICIAL TEST pairs ---------------
    model = CandidateModel()
    trainer = pl.Trainer(
        accelerator="auto",
        devices=1,
        precision=args.precision,
        max_epochs=-1,
        max_steps=-1,
        callbacks=[Timer(duration=timedelta(seconds=args.budget_seconds))],
        logger=False,
        enable_checkpointing=False,
    )
    t0 = time.monotonic()
    test_predictions = _train_and_predict_official_test(
        model, trainer, benchmark, args.budget_seconds
    )
    train_seconds = round(time.monotonic() - t0, 1)

    # ---- Build the submission AnnData exactly like fomo/utils/plantbench.py ------
    import pandas as pd

    from fomo.schema.enums import IO
    from plantbench.utils import create_anndata_obj

    s_col = benchmark.source_column_name
    t_col = benchmark.target_column_name

    # Merge preds onto the FULL test split so we cover EVERY pair the validator
    # expects; fill any gaps with 0.0 (plantbench rejects missing pairs otherwise).
    full_test = pd.read_parquet(
        benchmark.get_data(test=True)["test"], columns=[s_col, t_col]
    ).drop_duplicates(subset=[s_col, t_col])
    merged = full_test.merge(test_predictions, on=[s_col, t_col], how="left")
    merged[IO.PRED.value] = merged[IO.PRED.value].fillna(0.0)

    adata = create_anndata_obj(
        merged[s_col].tolist(),          # obs = source = dataset
        merged[t_col].tolist(),          # var = target = sequence_id
        merged[IO.PRED.value].tolist(),  # X   = predictions
    )

    # ---- SUBMIT (stable public API) ---------------------------------------------
    date = benchmark.submit(
        data=adata,
        submission_name=args.submission_name,
        metadata={
            "model_type": "baseline_locked_test_dryrun",
            "candidate_path": str(cand_path),
            "seed": args.seed,
            "budget_seconds": args.budget_seconds,
            "train_seconds": train_seconds,
            "note": "HUMAN-ONLY locked-test dry run; not an agent-loop score.",
        },
    )
    print(f"[locked-test] submitted '{args.submission_name}' at date={date}")

    # ---- EVALUATE (stable public API) -------------------------------------------
    # benchmark.preprocessing_fn / labels_preprocess_fn == compute_expression_difference
    # are applied AUTOMATICALLY (reference-subtraction via ref_seq_id); we pass
    # nothing extra. The score lands in LocalResultStore (NOT MLflow, NOT score.json).
    results = benchmark.evaluate(
        (args.submission_name, date),
        generate_artifacts=False,  # dry run: skip figures
    )

    # Pull the official-test Spearman-r out of the metrics mapping. DREAM's default
    # Regression metric is axis=1 (per-dataset), labelled "Spearman-r".
    spearman_keys = [k for k in results.metrics if "Spearman-r" in k]
    if len(spearman_keys) != 1:
        print(f"WARNING: expected one Spearman-r metric, found {spearman_keys}. "
              f"Recording all metrics; inspect manually.", file=sys.stderr)
    spearman = (float(results.metrics[spearman_keys[0]]) if len(spearman_keys) == 1
                else None)

    # ---- RECORD to the HUMAN-ONLY results file ----------------------------------
    results_path = Path(args.results_file).expanduser().resolve()

    # Isolation guard: refuse to write into the agent's score.json or the pod's /out.
    if results_path.name == "score.json":
        raise SystemExit(f"REFUSING: {results_path} looks like the agent score.json")
    if "/out/" in str(results_path):
        raise SystemExit(f"REFUSING: {results_path} is under the pod's ephemeral /out")

    results_path.parent.mkdir(parents=True, exist_ok=True)
    header = "\t".join(["date", "submission_name", "benchmark", "benchmark_version",
                        "seed", "spearman", "all_metrics_json", "candidate_path"])

    def _jsonable(v):
        # Keep scalars as floats; stringify arrays/curves so the TSV stays one line.
        if hasattr(v, "__float__") and getattr(v, "ndim", 0) in (0, None):
            try:
                return float(v)
            except (TypeError, ValueError):
                return str(v)
        return str(v)

    all_metrics = {k: _jsonable(v) for k, v in results.metrics.items()}
    write_header = not results_path.exists()
    with results_path.open("a") as f:
        if write_header:
            f.write(header + "\n")
        f.write("\t".join([
            date, args.submission_name, args.benchmark, args.benchmark_version,
            str(args.seed),
            ("" if spearman is None else f"{spearman:.6f}"),
            json.dumps(all_metrics),
            str(cand_path),
        ]) + "\n")

    # ---- Report WHERE it landed (the isolation proof) ---------------------------
    local_results_root = Path(os.environ["PLANTBENCH_HOME"]).expanduser() / \
        f"{benchmark.name_plus_version}" / "results"
    print("=" * 72)
    print(f"[locked-test] OFFICIAL-TEST Spearman-r = {spearman}")
    print(f"[locked-test] recorded in HUMAN-ONLY file : {results_path}")
    print(f"[locked-test] plantbench LocalResultStore : {local_results_root}")
    print("[locked-test] NOT written to the agent loop's /out/score.json or "
          "workdir results.tsv (those are ephemeral + git-untracked).")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
