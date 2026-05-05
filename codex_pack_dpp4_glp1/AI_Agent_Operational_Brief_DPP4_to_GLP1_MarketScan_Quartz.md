# AI Agent Operational Brief
## DPP-4 to GLP-1 Switcher Person-Month-Year Dataset on IU Quartz

## 0. Purpose of this document

This brief is written for an AI coding agent such as Codex.

The agent should use this document to build the project skeleton, configuration files, synthetic-data tests, and Quartz/Slurm workflow needed to construct a MarketScan person-month-year analytic dataset.

The agent must not read or process any row-level MarketScan data. The human analyst will later provide only metadata such as variable names, formats, local file layout, and code-list locations, then run the workflow inside the approved IU HPC environment.

## 1. Immediate data-engineering objective

Construct a person-month-year panel of commercially insured patients who switch from DPP-4 inhibitor therapy to GLP-1 receptor agonist therapy after GLP-1 availability in MarketScan.

The table should include:

- baseline covariates;
- baseline comorbidity;
- monthly treatment-state variables;
- financial-burden mediators;
- utilization and spending mediators;
- downstream outcomes;
- QC flags and cohort-screening variables.

This dataset will later support causal edge estimation, positive-control validation, causal knowledge graph construction, and economic digital-twin simulation.

No causal estimation is required in this first implementation step.

## 2. Where this task fits in the larger project

The broader collaboration is a MarketScan/HPC methods project on causal knowledge graphs and economic digital twins.

The conceptual architecture is:

1. define a paper-level causal diagram and estimands;
2. build a restricted-data-safe MarketScan data pipeline;
3. generate person-month state tables;
4. estimate causal edge families and validation controls;
5. store edge objects in a causal knowledge graph;
6. run digital-twin policy simulations.

This handoff concerns the first operational implementation step: build the DPP-4 to GLP-1 switcher person-month-year dataset.

## 3. Data-use constraints for the AI agent

The coding agent must assume the following constraints:

- Do not ingest or inspect row-level MarketScan files.
- Do not generate prompts containing MarketScan patient-level rows, claim lines, dates, cost values, or rare cell counts.
- Use synthetic data only for development and testing.
- Accept a metadata configuration file supplied by the human analyst that maps project concepts to local variable names and file paths.
- Generate code that can be run by the human analyst on IU Quartz/RED.
- Build scripts to validate schemas and fail gracefully if required variables are missing.
- Do not use LLMs, external APIs, or cloud services during data processing.

## 4. Primary exposure definition

### 4.1 Treatment contrast

The first operational exposure is a clean replacement switch from DPP-4 inhibitor therapy to GLP-1 therapy.

Source therapy:
- DPP-4 inhibitors.
- Examples: sitagliptin, saxagliptin, linagliptin, alogliptin, and fixed-dose combination products containing a DPP-4 inhibitor.

Destination therapy:
- GLP-1 receptor agonist or GLP-1-adjacent incretin therapy.
- Examples: exenatide, liraglutide, dulaglutide, semaglutide, lixisenatide.
- Tirzepatide should be optionally included as a GLP-1-like incretin product, controlled by configuration.

The actual NDC mapping must be supplied through external code-list files. Do not hard-code NDCs in the source scripts.

### 4.2 Index date and index month

For patient `i`, the index date is the date of the first qualifying GLP-1 fill after a 12-month GLP-1 washout period.

The index month is the calendar month containing the index date.

### 4.3 Required DPP-4 pre-index use

A patient must have evidence of DPP-4 use before the index date.

Default operational rule:

- at least one DPP-4 fill during the 180 days before the GLP-1 index date; and
- DPP-4 coverage active at index date or ending no more than `dpp4_preindex_grace_days` before the index date.

Sensitivity versions may require:

- at least two DPP-4 fills in baseline; or
- at least 60 covered DPP-4 days during baseline.

### 4.4 GLP-1 washout

To define new GLP-1 use, require no GLP-1 fills during the 365 days before the index date.

### 4.5 Replacement versus add-on switch

The primary cohort should be a replacement switch cohort.

Default rule:

- DPP-4 coverage is allowed to overlap with the initial GLP-1 fill during a short transition window.
- After DPP-4 runout plus a grace period, there should be no new DPP-4 fill within the post-index replacement assessment window.

Classify episodes into:

- `clean_replacement`: DPP-4 active before index and no meaningful post-index DPP-4 continuation.
- `addon_or_overlap`: DPP-4 continues meaningfully after GLP-1 start.
- `ambiguous_switch`: insufficient timing clarity.
- `reverse_switch`: GLP-1 to DPP-4, not part of the primary cohort.

Only `clean_replacement` is the primary analytic sample. Other categories should be retained as flags for sensitivity and descriptive tables.

## 5. Time period and observation windows

### 5.1 Recommended data pull

Use all available MarketScan years from 2017 through 2023 for the first build.

### 5.2 Primary index window

Define the primary switch index window as January 2018 through December 2022.

Rationale:

- 2017 provides a full 12-month lookback for 2018 switchers.
- 2023 provides a full 12-month follow-up for 2022 switchers.
- 2023 switchers do not have complete 12-month follow-up if the data end in December 2023, so they should be excluded from the primary complete-window cohort or placed in a partial-follow-up extension.

### 5.3 Event-time window

The target panel should include event months `-12` through `+12` relative to the index month.

Event month `0` is the GLP-1 index month.

The final table should retain both event time and calendar time:

- `calendar_year`
- `calendar_month`
- `year_month`
- `event_month`
- `index_year`
- `index_month`

## 6. Sample selection logic

The first-pass complete-window cohort should impose:

1. age 18-64 at index month, unless the team later includes other ages;
2. continuous enrollment with medical and pharmacy benefits from 12 months before index through 12 months after index;
3. no GLP-1 fill in the 12-month baseline washout;
4. qualifying DPP-4 pre-index use;
5. first GLP-1 fill in the primary index window;
6. clean replacement classification under the default DPP-4 discontinuation rule;
7. valid cost-sharing and spending fields for financial-burden construction, if available in the extract.

The code must generate a screening waterfall table with counts after each criterion.

## 7. Required feature families

### 7.1 Baseline variables

Baseline variables are measured in the 12 months before index unless otherwise specified.

Demographics and enrollment:
- age;
- sex;
- plan type;
- region;
- employer/plan identifiers if available and permitted;
- continuous enrollment flags;
- pharmacy benefit flags;
- coverage months.

Baseline spending:
- total medical allowed;
- total pharmacy allowed;
- total out-of-pocket;
- plan-paid amounts;
- patient-paid amounts.

Baseline utilization:
- ED visits;
- inpatient admissions;
- outpatient visits;
- office visits.

Baseline drug history:
- DPP-4 days covered;
- metformin;
- insulin;
- SGLT2 inhibitors;
- sulfonylureas;
- TZDs;
- other diabetes medications.

Baseline disease flags:
- diabetes;
- obesity;
- chronic kidney disease;
- CVD/ASCVD;
- heart failure;
- hypertension;
- dyslipidemia;
- sleep apnea;
- liver disease;
- mental health;
- substance use.

### 7.2 Comorbidity variables

Create both broad and disease-specific comorbidity features.

Preferred measures:

- Elixhauser indicators and count/summary score if code lists are available.
- Charlson/NCI-style score as a compact sensitivity measure if code lists are available.
- Clinical bundles relevant to GLP-1 and diabetes:
  - CKD;
  - CVD/ASCVD;
  - heart failure;
  - diabetic complications;
  - hypertension;
  - dyslipidemia;
  - liver disease;
  - obesity;
  - depression/anxiety;
  - substance use.

Default claims ascertainment rule:

- one inpatient claim with the relevant diagnosis; or
- two outpatient claims separated by at least 30 days within the baseline lookback.

This rule should be configurable by condition family.

### 7.3 Monthly treatment-state variables

For every person-month from event month -12 to +12, construct:

- active DPP-4 coverage share;
- active GLP-1 coverage share;
- active metformin coverage share;
- active insulin coverage share;
- active SGLT2 coverage share;
- active sulfonylurea coverage share;
- active TZD coverage share;
- other diabetes medication coverage shares;
- any GLP-1 fill indicator;
- any DPP-4 fill indicator;
- days supply filled by class;
- discontinuation flag;
- switch-back flag;
- add-on/overlap flag;
- cumulative months since GLP-1 initiation.

Coverage should be constructed from pharmacy fill date and days supply with stockpiling/carry-forward logic for early refills.

### 7.4 Financial-burden mediators

If the extract includes copay, coinsurance, deductible, patient-pay, plan-pay, and allowed amount fields, construct monthly:

- GLP-1-specific patient OOP;
- DPP-4-specific patient OOP;
- total diabetes-drug OOP;
- total pharmacy OOP;
- total medical OOP;
- total medical plus pharmacy OOP;
- GLP-1 OOP share of total OOP;
- OOP shock indicator relative to baseline median or baseline mean;
- top-decile or top-quartile OOP burden indicator.

The code should proceed even if some cost-sharing components are missing, as long as the config defines which fields exist.

Default patient OOP formula:

`patient_oop = copay + coinsurance + deductible`

If a trusted total patient-pay field exists, the code should compare it to the component-sum measure and report discrepancies.

### 7.5 Monthly outcomes

For every person-month, construct:

- total medical allowed amount;
- total pharmacy allowed amount;
- total non-GLP spending;
- outpatient spending;
- inpatient spending;
- ED spending;
- ED visit count;
- inpatient admission count;
- outpatient visit count;
- diabetes-drug spending excluding GLP-1;
- GI event proxies;
- pancreatitis/gallbladder proxies if desired;
- hypoglycemia/hyperglycemia/DKA proxies if code lists are available;
- CKD/CVD acute-event proxies if code lists are available.

## 8. Target output table

The primary output should be a Parquet dataset named:

`person_month_state_dpp4_to_glp1`

Recommended grain:

`one row per enrollee_id_hash x index_episode_id x event_month`

Core columns:

Identifiers:
- `enrollee_id_hash`
- `episode_id`

Time:
- `index_date`
- `index_month`
- `calendar_year`
- `calendar_month`
- `year_month`
- `event_month`

Cohort flags:
- `primary_clean_replacement`
- `addon_or_overlap`
- `ambiguous_switch`
- `reverse_switch`

Baseline covariates:
- demographics;
- baseline utilization;
- baseline spending;
- comorbidity indicators.

Monthly treatment states:
- class-specific coverage shares;
- fill indicators;
- persistence/discontinuation fields.

Mediators:
- OOP burden;
- adherence/persistence;
- switch-back/discontinuation;
- care intensity.

Outcomes:
- utilization;
- spending;
- complication proxies.

QC flags:
- continuous enrollment;
- valid cost fields;
- valid pharmacy benefit;
- feature completeness.

A separate `cohort_waterfall` table and `run_manifest` table should also be created.

## 9. Quartz/RED/HPC execution plan

The codebase should be designed for local synthetic-data testing and Quartz production execution.

### 9.1 Repository skeleton

Recommended structure:

```text
project_root/
  README.md
  config/
    config_template_dpp4_to_glp1_marketscan.yaml
    local_config.yaml              # never committed if it contains restricted paths
  code_lists/
    glp1_ndc.csv
    dpp4_ndc.csv
    diagnosis_groups/
  src/
    validate_config.py
    make_synthetic_data.py
    stage_01_ingest_standardize.py
    stage_02_build_drug_episodes.py
    stage_03_build_enrollment_spine.py
    stage_04_build_comorbidity.py
    stage_05_build_financial_burden.py
    stage_06_build_outcomes.py
    stage_07_assemble_person_month.py
    stage_08_qc_reports.py
  tests/
    test_config_validation.py
    test_synthetic_switch_logic.py
    test_event_time.py
    test_oop_construction.py
    test_cohort_waterfall.py
  slurm/
    slurm_run_stage_array_template.sbatch
  docs/
    AI_Agent_Operational_Brief_DPP4_to_GLP1_MarketScan_Quartz.md
  logs/
```

### 9.2 Stage design

Stage 1: Ingest and standardize metadata-defined tables.
- Read raw files according to config.
- Standardize variable names internally.
- Write partitioned Parquet by year and enrollee hash.

Stage 2: Build drug episodes.
- Map NDCs to drug classes.
- Construct days-supply intervals.
- Apply stockpiling/carry-forward logic.
- Detect GLP-1 initiation.
- Detect DPP-4 pre-index use.
- Classify switch type.

Stage 3: Build enrollment spine.
- Construct monthly enrollment panel.
- Apply continuous enrollment and pharmacy-benefit rules.
- Keep person-months from event month -12 to +12 for eligible switch episodes.

Stage 4: Build comorbidity features.
- Use baseline diagnosis claims.
- Apply inpatient/outpatient diagnosis rules.
- Build Elixhauser, Charlson, and clinical bundles if code lists exist.

Stage 5: Build financial-burden features.
- Aggregate pharmacy and medical OOP variables by person-month.
- Construct GLP-1-specific and total OOP burden.
- Construct OOP shock and high-OOP indicators.

Stage 6: Build utilization and spending outcomes.
- Aggregate medical and pharmacy outcomes by person-month.
- Create ED/IP/OP utilization and disease-specific proxy outcomes.

Stage 7: Assemble person-month state table.
- Merge enrollment, drug states, comorbidity, financial burden, and outcomes.
- Enforce one-row-per-person-episode-event-month.
- Write final Parquet table.

Stage 8: QC reports.
- Generate cohort waterfall.
- Generate missingness tables.
- Generate event-time counts.
- Generate treatment-state summaries.
- Generate OOP sanity checks.
- Generate run manifest.

### 9.3 Slurm execution

All stages should support:

- `--config`
- `--shard-id`
- `--n-shards`
- optional `--year`
- optional `--stage`

The shard key should be a stable hash of enrollee ID.

The code should be restartable. If a shard output already exists and passes checksum/manifest validation, the stage should skip or overwrite only when explicitly requested.

## 10. Synthetic data requirements

The agent should create synthetic data generators for:

- enrollment table;
- pharmacy table;
- medical table;
- diagnosis table;
- procedure table if needed.

The synthetic data should include cases for:

- clean DPP-4 to GLP-1 switch;
- DPP-4 add-on overlap;
- prior GLP-1 use during washout;
- incomplete baseline enrollment;
- incomplete follow-up enrollment;
- missing cost-sharing fields;
- early refill/stockpiling;
- switch-back from GLP-1 to DPP-4.

Synthetic data should be small and safe to commit.

## 11. Validation requirements

At minimum, unit tests should verify:

- DPP-4 pre-index use detection;
- GLP-1 washout enforcement;
- index-date assignment;
- event-month construction;
- clean replacement classification;
- add-on/overlap classification;
- continuous enrollment logic;
- stockpiling logic;
- OOP construction from copay/coinsurance/deductible;
- one-row-per-person-episode-event-month final table structure;
- cohort waterfall counts on synthetic data.

## 12. Deliverables expected from Codex

Codex should produce:

1. a runnable repository skeleton;
2. metadata-driven config validation;
3. synthetic data generator;
4. stage scripts with command-line interfaces;
5. unit tests;
6. Slurm templates;
7. a basic QC-report script;
8. README instructions for local synthetic tests and Quartz production runs.

Codex should not produce:
- causal estimates;
- substantive results;
- tables with MarketScan data;
- charts using MarketScan data;
- LLM-derived features from MarketScan data.

## 13. Suggested first implementation order

1. Build config parser and validator.
2. Build synthetic data generator.
3. Implement exposure/switch classification on synthetic data.
4. Implement event-time spine.
5. Implement financial-burden construction on synthetic data.
6. Implement final person-month assembly.
7. Add QC waterfall.
8. Add Slurm wrapper.
9. Add unit tests.
10. Prepare for metadata mapping once the human analyst provides local variable names.

## 14. Terminology

- DPP-4: dipeptidyl peptidase-4 inhibitor.
- GLP-1: glucagon-like peptide-1 receptor agonist; may include tirzepatide if configured.
- Index date: first qualifying GLP-1 fill after washout.
- Index month: calendar month of index date.
- Event month: month relative to index month.
- Clean replacement: DPP-4 to GLP-1 switch without meaningful post-index DPP-4 continuation.
- Add-on/overlap: GLP-1 starts but DPP-4 continues meaningfully.
- OOP: out-of-pocket patient cost burden.
- Person-month state table: longitudinal analytic table with one row per patient episode and month.
