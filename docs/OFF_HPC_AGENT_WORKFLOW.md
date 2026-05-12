# Off-HPC Agent Workflow and Safe Return to HPC

This project should use AI agents for code generation, documentation, and manuscript drafting only in an environment that does not have technical access to restricted MarketScan data.

## Core Rule

Do not run an AI coding agent under a user account or machine session that can read restricted MarketScan folders. Prompt instructions and human review are useful, but they are not a filesystem access control. If an agent process runs as a user who can read a restricted path, then the agent can potentially read that path.

## Recommended Workflow

1. Work on the laptop or another non-restricted development environment.
2. Clone the GitHub repository to the laptop.
3. Use AI tools only against this source repository, public code lists, synthetic data generators, tests, and manuscript templates.
4. Do not copy raw MarketScan data, derived restricted outputs, metadata manifests, logs, or licensed MarketScan documentation to the laptop.
5. Run local tests using synthetic data only.
6. Push source-code changes to GitHub.
7. On the HPC, pull the reviewed source-code changes from GitHub.
8. Run the actual MarketScan workflow manually through Slurm from the approved restricted workspace.
9. Keep all raw data, derived parquet files, aggregate output tables, logs, and rendered reports inside the approved HPC project folder unless they have been cleared for release.

## Laptop Setup

Use GitHub as the transfer mechanism for source code, not `scp` or `rsync` from restricted output folders.

```bash
git clone git@github.com:CongGian/marketscan_glp1.git
cd marketscan_glp1
git checkout -b feature/my-change
```

For code generation, point the AI agent only at this checkout. The laptop checkout should contain source files, tests, public concept lists, and templates. It should not contain restricted data or MarketScan output.

## Local Development With Synthetic Data

Use the synthetic workflow to validate code structure and logic:

```bash
Rscript scripts/make_synthetic_data.R
Rscript scripts/run_tests.R
Rscript scripts/run_synthetic_pipeline.R
```

The synthetic data are only for code development. They are not evidence for the empirical paper.

## Returning Code to HPC

The safest transfer direction is:

```text
laptop source repo -> GitHub -> HPC source repo -> manual Slurm run
```

On the HPC:

```bash
cd /PATH/TO/REPO
git fetch origin
git status --short
git diff --stat HEAD..origin/main
git pull --ff-only origin main
```

Then run the relevant Slurm script manually, for example:

```bash
sbatch slurm/run_stage_08_descriptives.sbatch
```

Do not let an AI agent submit jobs or inspect restricted outputs. If an output needs interpretation, paste only approved aggregate QC or descriptive summaries into the chat.

## Safe Transfer Rules

Use an allowlist mindset. These are generally safe to move through GitHub:

- `R/`
- `scripts/`
- `slurm/`
- `tests/`
- `tools/`
- `docs/*.md`
- public concept/code-list files under `code_lists/`
- sanitized config templates

These should not be moved to GitHub or a laptop unless separately approved:

- raw MarketScan files
- derived parquet, DuckDB, RDS, SAS, XPT, or CSV outputs from restricted data
- row-level samples
- metadata manifests generated from the restricted delivery
- job logs that include restricted paths or output summaries
- licensed MarketScan user guides, data dictionaries, or codebooks
- rendered manuscripts or tables containing non-cleared empirical results
- local config files with restricted paths or credentials

Before committing from the HPC, inspect exactly what will be uploaded:

```bash
git status --short
git diff --cached --name-only
git diff --cached --stat
```

Prefer explicit `git add` commands instead of `git add .`.

## If File Transfer Is Needed Without Git

Avoid transferring from restricted data folders to the laptop. If a non-Git transfer is unavoidable, transfer only from a clean source checkout and use explicit excludes:

```bash
rsync -av \
  --exclude='.git/' \
  --exclude='outputs/' \
  --exclude='logs/' \
  --exclude='metadata/' \
  --exclude='duckdb/' \
  --exclude='data/' \
  --exclude='raw/' \
  --exclude='derived/' \
  --exclude='*.parquet' \
  --exclude='*.duckdb*' \
  --exclude='*.rds' \
  --exclude='*.RDS' \
  --exclude='*.sas7bdat' \
  --exclude='*.xpt' \
  --exclude='docs/*.pdf' \
  /PATH/TO/REPO/ laptop_or_clean_destination/
```

Git remains preferable because the committed file list is auditable.

## Operational Boundary for AI Agents

For future work, the cleanest boundary is to run AI agents only on:

- the laptop source checkout, or
- an institutional sandbox that has no Unix permissions to restricted data, or
- an approved local model environment with platform-level controls.

Actual MarketScan execution should remain a human-run HPC step until a formally approved sandbox exists.
