# README for Codex: DPP-4 to GLP-1 MarketScan Person-Month Build

## Purpose

This folder contains the operational handoff for building the first MarketScan/HPC module of the causal graph and economic digital twin project.

The immediate task is to create a person-month-year analytic dataset for patients who switch from DPP-4 inhibitors to GLP-1 therapy.

The AI coding agent must build infrastructure only:
- repository skeleton
- configuration system
- schema validation
- synthetic test data
- stage scripts
- Slurm templates
- QC/reporting scaffolds

The agent must not read, inspect, infer from, summarize, or process row-level MarketScan data.

## Key design decisions

Primary exposure:
- Clean replacement switch from DPP-4 inhibitor therapy to GLP-1 therapy.

Recommended data years:
- Pull MarketScan 2017-2023.

Primary switch index window:
- January 2018 through December 2022.

Rationale:
- 2017 is needed for 12-month lookback for 2018 switchers.
- 2023 is needed for 12-month follow-up for 2022 switchers.
- 2023 index switchers are not in the primary complete-window cohort unless partial follow-up is later allowed.

Primary event window:
- Event months -12 through +12 around the GLP-1 index month.

Primary output:
- `person_month_state_dpp4_to_glp1`
- Grain: one row per patient/episode/event_month.

## Files in this folder

1. `AI_Agent_Operational_Brief_DPP4_to_GLP1_MarketScan_Quartz.md`
   - Main design and operational instructions.

2. `config_template_dpp4_to_glp1_marketscan.yaml`
   - Metadata-only configuration template.
   - The human analyst fills in local MarketScan variable names and approved HPC paths.

3. `slurm_run_stage_array_template.sbatch`
   - Generic Slurm job-array template for Quartz.

4. `MANIFEST.txt`
   - File list.

## Suggested first Codex prompt

Read all files in this folder. Build a Python project skeleton that can run locally on synthetic data and later on IU Quartz using metadata-only configuration. Do not assume access to row-level MarketScan data. Implement schema validation, synthetic data generation, stage scripts, and tests for constructing a person-month state table for DPP-4 to GLP-1 replacement switchers. Use the YAML config as the source of truth for paths, variable names, event windows, and cohort definitions.
