# MarketScan GLP-1 Medication Transition Workflow

This repository contains source code, public concept/code-list artifacts,
synthetic-data tests, and documentation for building medication-transition
cohorts in claims data. It is designed so code can be developed on a laptop
without access to restricted MarketScan data, then transferred back to an
approved HPC workspace for human-run execution.

## Data Boundary

The GitHub repository must not contain:

- raw MarketScan files;
- derived restricted parquet, DuckDB, RDS, SAS, XPT, or CSV outputs;
- metadata manifests generated from restricted data;
- job logs from restricted runs;
- licensed MarketScan codebooks, user guides, or data dictionaries;
- rendered manuscripts or empirical tables/figures that have not been cleared;
- local config files with real restricted paths.

Use placeholders in committed files. Real data paths should exist only in
untracked local config files or environment variables inside the approved HPC
workspace.

## Local Development

Clone the repo and create a feature branch:

```bash
git clone git@github.com:CongGian/marketscan_glp1.git
cd marketscan_glp1
git checkout -b feature/transition-atlas
```

Develop against synthetic data only:

```bash
Rscript scripts/run_tests.R
Rscript scripts/make_synthetic_data.R
Rscript scripts/run_synthetic_pipeline.R
```

If you open a local Codex session, start from the repo root and follow
`AGENTS.md` plus `docs/LOCAL_CODEX_HANDOFF.md`.

## HPC Execution

Do not run AI agents in the restricted HPC environment. On HPC, pull reviewed
source code manually, set local paths through environment variables or an
untracked local config file, and submit Slurm jobs yourself.

Typical pattern:

```bash
git fetch origin
git pull --ff-only origin main

export PROJECT_ROOT="$PWD"
export RESTRICTED_ROOT="/PATH/TO/RESTRICTED_WORKSPACE"
export RAW_ROOT="/PATH/TO/RESTRICTED_MARKETSCAN_PARQUET"
export CONFIG="$PROJECT_ROOT/config/local_config.yaml"

sbatch slurm/run_stage_01_drug_fills.sbatch
```

`config/local_config.yaml` is intentionally ignored by Git.

## Pipeline Structure

Core R modules live in `R/`.

Command-line wrappers live in `scripts/`.

Slurm templates live in `slurm/`.

Tests live in `tests/` and use synthetic data.

Public concept lists live in `code_lists/`.

Operational documentation lives in `docs/`.

## Current Scientific Direction

The original implementation focused on a DPP-4 to GLP-1-like clean-replacement
cohort. The next planned step is to generalize this into a transition atlas that
compares candidate starting therapy classes before GLP-1 initiation, including
metformin, DPP-4 inhibitors, SGLT2 inhibitors, sulfonylureas, and insulin.

The transition atlas should compare sample size, clean replacement rate,
continuation/add-on patterns, baseline clinical burden, and cost decomposition.
This will help decide whether DPP-4 remains the cleanest substitution design or
whether a more common starting class is better justified.

## Cost Interpretation

Total spending around GLP-1 initiation can mechanically rise because the GLP-1
drug cost is included. Analyses should decompose cost into at least:

- GLP-1-like pharmacy spending;
- non-GLP-1 pharmacy spending;
- medical spending;
- patient out-of-pocket components when available.

Medical-only and non-GLP-1 spending are better checks for whether costs outside
the GLP-1 drug price change around the transition.

## Key Documents

- `AGENTS.md`: rules for local AI-assisted code generation.
- `docs/LOCAL_CODEX_HANDOFF.md`: context for a new local Codex session.
- `docs/OFF_HPC_AGENT_WORKFLOW.md`: safe off-HPC development workflow.
- `docs/PIPELINE_COORDINATION.md`: stage order and data boundary.
- `docs/STAGE08_DESCRIPTIVES.md`: aggregate descriptive-output design.
- `code_lists/README.md`: public code-list provenance and limitations.
