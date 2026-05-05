# MarketScan GLP-1 and DPP-4 to GLP-1 Switcher Build

This repository is a restricted-data-safe code and documentation handoff for MarketScan GLP-1 work.

It currently contains:

- `01_build_glp1_pool.R`: a narrow DuckDB/R script that builds a 2022 GLP-1 initiator pool from MarketScan pharmacy and enrollment parquet shards.
- `inputs/glp1_ndc11.csv`: an external GLP-1 NDC11 code list used by `01_build_glp1_pool.R`.
- `codex_pack_dpp4_glp1/`: a metadata-only operational pack for building a DPP-4 to GLP-1 switcher person-month dataset on IU Quartz/RED.
- `AGENT_HPC_HANDOFF.md`: read-this-first instructions for a new Codex or AI coding agent session on HPC.
- `MARKETSCAN_METADATA_REQUIREMENTS.md`: the metadata checklist needed before running the full exercise against MarketScan.

## Critical Data-Use Boundary

Do not commit, paste, summarize, or send row-level MarketScan data to an AI agent or external service.

Safe inputs for AI-assisted development are:

- metadata-only configuration files;
- table and column names;
- schema summaries;
- file-layout patterns;
- code-list file names and provenance;
- synthetic test data;
- non-sensitive aggregate QC counts when permitted by the data-use agreement.

Unsafe inputs include:

- patient-level claim rows;
- enrollee IDs or hashes derived from real data;
- claim-line dates and cost values from real data;
- rare-cell or small-cell outputs;
- raw parquet, SAS, CSV, DuckDB, or extracted MarketScan data files.

## Current GLP-1 Pool Script

`01_build_glp1_pool.R` is a single-year prototype. It currently assumes:

- raw 2022 parquet files under `/N/project/mscan_trial/data/parquet_raw/2022`;
- pharmacy `D` shards matching `*_d_*.snappy.parquet`;
- enrollment `T` shards matching `*_t_*.snappy.parquet`;
- pharmacy columns `ENROLID`, `SVCDATE`, `NDCNUM`, `DAYSUPP`;
- enrollment columns `ENROLID`, `DTSTART`, `DTEND`, `RX`;
- `RX = '1'` means pharmacy benefit enrollment;
- integer dates, if present, are days since `1960-01-01`;
- output paths under `/N/project/mscan_trial/trial_users/tgian`.

The script:

1. reads the GLP-1 NDC11 list;
2. discovers pharmacy and enrollment parquet shards;
3. validates required columns;
4. standardizes fill and enrollment dates;
5. builds continuous pharmacy-benefit enrollment spells;
6. identifies each enrollee's first GLP-1 fill;
7. keeps patients with pharmacy coverage from 180 days before through 180 days after index;
8. writes `glp1_pool.parquet` and `glp1_rx_pool.parquet`.

Before running it on another HPC project path, update the hard-coded `data_dir` and `work_dir` or refactor it to use a config file.

## Full DPP-4 to GLP-1 Exercise

The broader target is a person-month analytic dataset for patients who cleanly replace DPP-4 therapy with GLP-1 therapy.

Primary design:

- data years: 2017 through 2023;
- index window: January 2018 through December 2022;
- baseline: 12 months pre-index;
- follow-up: 12 months post-index;
- event months: `-12` through `+12`;
- exposure: first qualifying GLP-1 fill after 365-day GLP-1 washout;
- required source therapy: DPP-4 use before index;
- primary cohort: `clean_replacement`;
- output grain: one row per enrollee episode per event month.

The detailed operational design is in:

- `codex_pack_dpp4_glp1/AI_Agent_Operational_Brief_DPP4_to_GLP1_MarketScan_Quartz.md`
- `codex_pack_dpp4_glp1/config_template_dpp4_to_glp1_marketscan.yaml`
- `MARKETSCAN_METADATA_REQUIREMENTS.md`

## Recommended HPC Workflow

1. Copy or clone this repository into the approved IU Slate or project workspace.
2. Start a new Codex session inside the repository on HPC.
3. Tell the agent to read `AGENT_HPC_HANDOFF.md`, then `MARKETSCAN_METADATA_REQUIREMENTS.md`, then the files in `codex_pack_dpp4_glp1/`.
4. Fill a local metadata config from `codex_pack_dpp4_glp1/config_template_dpp4_to_glp1_marketscan.yaml`.
5. Keep the local config out of git if it contains restricted paths or operational details.
6. Develop and test against synthetic data first.
7. Run MarketScan processing only inside the approved HPC environment.

## Files That Should Not Be Committed

The `.gitignore` is set up to block common restricted-data artifacts, including local configs, raw/derived data directories, parquet files, DuckDB databases, outputs, and logs.

Before every push from HPC, run:

```bash
git status --short
```

If any raw, derived, output, or patient-level files appear, do not commit them.

