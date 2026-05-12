# Pipeline Coordination

This project is being built as a restricted-data-safe, metadata-driven pipeline.
Development and tests use synthetic data only. Real MarketScan processing must run
inside the approved HPC environment and must not export row-level claims.

Generated restricted artifacts should live under:

```text
/PATH/TO/RESTRICTED_WORKSPACE
```

The repository under `/PATH/TO/REPO` should remain code, public code
lists, documentation, tests, and synthetic fixtures only.

AI assistants should write and test code with synthetic data only. The analyst
runs all commands that touch restricted paths, including metadata extraction,
parquet footer checks, row counts, Stage 01, Stage 02, and later production
stages. The analyst may share safe aggregate/log summaries back into the
development workflow when allowed by the data-use agreement.

## Current Parallel Work Plan

Work is split into disjoint modules:

- Configuration layer: `config/config_template.yaml`, `R/config.R`, `tests/test_config.R`
- Synthetic data: `R/synthetic_data.R`, `scripts/make_synthetic_data.R`, `tests/test_synthetic_data.R`
- Drug episodes and switch classification: `R/drug_episodes.R`, `tests/test_drug_episodes.R`
- Stage 01 pharmacy extraction: `R/stage_01_drug_fills.R`, `scripts/stage_01_extract_drug_fills.R`, `slurm/run_stage_01_drug_fills.sbatch`, `tests/test_stage_01_drug_fills.R`
- Stage 02 switch candidates: `R/stage_02_switch_candidates.R`, `scripts/stage_02_extract_switch_candidates.R`, `slurm/run_stage_02_switch_candidates.sbatch`, `tests/test_stage_02_switch_candidates.R`
- Stage 03 enrollment flags: `R/stage_03_enrollment.R`, `scripts/stage_03_extract_enrollment.R`, `slurm/run_stage_03_enrollment.sbatch`, `tests/test_stage_03_enrollment.R`
- Stage 04 person-month spine: `R/stage_04_person_month_spine.R`, `scripts/stage_04_build_person_month_spine.R`, `slurm/run_stage_04_person_month_spine.sbatch`, `tests/test_stage_04_person_month_spine.R`
- Stage 05 pharmacy features: `R/stage_05_pharmacy_features.R`, `scripts/stage_05_add_pharmacy_features.R`, `slurm/run_stage_05_pharmacy_features.sbatch`, `tests/test_stage_05_pharmacy_features.R`
- Stage 06 medical features: `R/stage_06_medical_features.R`, `scripts/stage_06_add_medical_features.R`, `slurm/run_stage_06_medical_features.sbatch`, `tests/test_stage_06_medical_features.R`
- Stage 07 final sample and descriptives: `R/stage_07_final_sample.R`, `scripts/stage_07_build_final_sample.R`, `slurm/run_stage_07_final_sample.sbatch`, `tests/test_stage_07_final_sample.R`
- Stage 08 figure-ready aggregate descriptives: `R/stage_08_descriptive_tables.R`, `R/stage_08_descriptive_plots.R`, `scripts/stage_08_build_descriptive_tables.R`, `scripts/stage_08_make_figures.R`, `slurm/run_stage_08_descriptives.sbatch`, `tests/test_stage_08_descriptive_tables.R`, `tests/test_stage_08_descriptive_plots.R`
- Person-month assembly and feature helpers: `R/person_month.R`, `tests/test_person_month.R`
- Shared runners/docs: `scripts/run_tests.R`, `docs/PIPELINE_COORDINATION.md`

Workers must not edit files outside their assigned write scope unless explicitly
coordinated.

## Stage Order

1. Load and validate config.
2. Build or load code lists.
3. Stage 01: scan pharmacy `D` files with DuckDB and write reduced diabetes-drug fills.
4. Stage 02: identify candidate switch episodes and classify switch type.
5. Stage 03: build continuous enrollment flags and index-time demographics.
6. Stage 04: build event-month spine for enrolled clean replacements.
7. Stage 05: add monthly pharmacy treatment states and Rx spending/OOP.
8. Stage 06: add baseline covariates, comorbidities, medical spending, and utilization.
9. Stage 07: assemble the final person-month table and aggregate QC/descriptive outputs.
10. Stage 08: produce aggregate figure-ready CSVs and optional aggregate-only figures.

## Data Boundary

Allowed for development:

- schema metadata;
- code-list files and provenance;
- synthetic data;
- aggregate QC counts if allowed by the DUA and suppressed for small cells.

Not allowed in prompts, commits, or exported artifacts:

- row-level MarketScan claims;
- `ENROLID` values or hashes derived from real data;
- real service/fill dates;
- real claim diagnosis/NDC values observed in MarketScan rows;
- real costs or claim-line financial values;
- rare-cell outputs.

## DuckDB Plan

The production pipeline should use DuckDB through R for large Parquet scans. The
unit-tested business logic stays in pure R where feasible. Production stages
should use DuckDB to reduce raw data early:

1. Read only pharmacy columns needed for diabetes-drug fills. Implemented as Stage 01.
2. Join against public NDC code lists. Implemented as Stage 01.
3. Write reduced drug-fill parquet intermediates by year/shard. Implemented as Stage 01.
4. Identify candidate switchers.
5. Pull enrollment and medical claims only for candidate `ENROLID`s.
6. Aggregate to person-month before writing final outputs.

This avoids repeated full scans of the largest medical claim files.
