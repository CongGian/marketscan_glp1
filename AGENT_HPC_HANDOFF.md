# Agent HPC Handoff

This file is written for the next Codex or AI coding agent session that will run inside the approved HPC environment.

## First Instructions

Read these files in order:

1. `README.md`
2. `MARKETSCAN_METADATA_REQUIREMENTS.md`
3. `codex_pack_dpp4_glp1/README_for_Codex.md`
4. `codex_pack_dpp4_glp1/AI_Agent_Operational_Brief_DPP4_to_GLP1_MarketScan_Quartz.md`
5. `codex_pack_dpp4_glp1/config_template_dpp4_to_glp1_marketscan.yaml`
6. `01_build_glp1_pool.R`

Your first job is to build or refine infrastructure, not to produce substantive MarketScan results.

## Non-Negotiable Data Boundary

Do not read, inspect, paste, summarize, export, or commit row-level MarketScan data unless the human analyst explicitly runs the code locally inside the approved environment and the content stays inside that environment.

Do not send row-level data to an LLM, external API, cloud service, browser tool, or chat transcript.

Use only:

- metadata supplied by the human analyst;
- table names and schemas;
- code-list paths and code-list structure;
- synthetic data;
- permitted aggregate QC outputs.

If a task requires looking at real row-level records, stop and ask the human analyst to run a restricted-data-safe diagnostic locally and provide only metadata or approved aggregate results.

## Repository State at Handoff

The repository contains a working prototype plus a broader DPP-4 to GLP-1 design pack.

`01_build_glp1_pool.R`:

- language: R;
- engine: DuckDB over parquet;
- scope: 2022 GLP-1 pool only;
- required raw modules: pharmacy `D` and enrollment `T`;
- required pharmacy fields: `ENROLID`, `SVCDATE`, `NDCNUM`, `DAYSUPP`;
- required enrollment fields: `ENROLID`, `DTSTART`, `DTEND`, `RX`;
- current enrollment rule: continuous pharmacy benefit spell around index;
- current coverage window: 180 days before through 180 days after index;
- output: `glp1_pool.parquet`, `glp1_rx_pool.parquet`.

`codex_pack_dpp4_glp1/`:

- scope: full DPP-4 to GLP-1 switcher person-month build;
- required years: 2017 through 2023;
- primary index window: 2018-01-01 through 2022-12-31;
- target table: `person_month_state_dpp4_to_glp1`;
- output grain: one row per enrollee episode per event month;
- target event months: `-12` through `+12`;
- requested implementation style: metadata-driven config, synthetic tests, stage scripts, Slurm templates, QC reports.

## Expected Development Path

Build a production-safe project skeleton before touching MarketScan data:

1. Add a config parser and validator.
2. Add synthetic data generation.
3. Implement switch classification against synthetic data.
4. Implement drug episode construction and stockpiling logic.
5. Implement event-month spine construction.
6. Implement baseline comorbidity, spending, and utilization features.
7. Implement financial-burden features.
8. Assemble the person-month state table.
9. Add QC reports and a cohort waterfall.
10. Add tests for each core rule.
11. Add or refine Slurm wrappers.

The config template in `codex_pack_dpp4_glp1/config_template_dpp4_to_glp1_marketscan.yaml` is the source of truth for local paths, table names, variable names, years, event windows, and cohort definitions.

## Metadata Needed Before Production Runs

The human analyst should provide a local metadata config with:

- approved raw, derived, output, log, and code-list paths;
- data years and module availability;
- table or file naming patterns;
- column mappings for enrollment, pharmacy, inpatient, outpatient, facility, diagnosis, procedure, and cost fields;
- NDC code lists for GLP-1, DPP-4, and other diabetes medication classes;
- diagnosis and procedure code groups for comorbidity and outcomes;
- date encodings and missing-value conventions;
- benefit flag values;
- cost field definitions and units;
- Slurm account, partition, shard count, CPU, memory, and wall-time settings.

See `MARKETSCAN_METADATA_REQUIREMENTS.md` for the detailed checklist.

## Implementation Guardrails

- Do not hard-code MarketScan local paths in reusable stage scripts. Put them in local config files.
- Do not hard-code NDCs in source code. Load code lists from configured files.
- Normalize NDCs to 11-digit strings before matching.
- Explicitly handle date encoding, including SAS-style days since `1960-01-01` if applicable.
- Treat cost fields carefully. Confirm whether values are dollars, cents, signed reversals, netted amounts, or line-level amounts.
- Write restartable outputs by stage, year, and shard.
- Add manifest or checksum logic before skipping completed shard outputs.
- Generate schema-validation failures that name the missing concept and the configured source field.
- Keep rare-cell and patient-level details out of logs and QC reports.

## Suggested First Prompt for the HPC Session

```text
Read README.md, AGENT_HPC_HANDOFF.md, MARKETSCAN_METADATA_REQUIREMENTS.md, and all files in codex_pack_dpp4_glp1/. Build a metadata-driven Python project skeleton for the DPP-4 to GLP-1 MarketScan person-month pipeline. Use synthetic data only. Do not inspect row-level MarketScan data. Implement config validation, synthetic tests, stage CLIs, Slurm wrappers, and QC scaffolding. Treat the YAML config template as the source of truth.
```

