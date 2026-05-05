# MarketScan Metadata Requirements

This document lists the metadata needed to convert this repository into a production pipeline for the DPP-4 to GLP-1 switcher person-month exercise.

No row-level MarketScan data is needed for AI-assisted development.

## 1. Approved Paths and File Layout

Provide the approved HPC paths for:

- raw MarketScan root;
- derived/intermediate root;
- final output root;
- log root;
- code-list root;
- temporary scratch root, if required;
- project repository root on Slate or project storage.

Provide file layout details:

- file format: parquet, SAS, CSV, DuckDB, or database tables;
- compression: snappy, zstd, gzip, none;
- partitioning by year, module, enrollee shard, or other key;
- filename patterns for each module and year;
- whether files are one table per year or many shards per year.

For the current R prototype, the known pattern is:

- pharmacy `D` shards: `*_d_*.snappy.parquet`;
- enrollment `T` shards: `*_t_*.snappy.parquet`.

Confirm whether that pattern applies to 2017 through 2023.

## 2. Years and Modules

Confirm availability for each year 2017 through 2023.

Needed modules or equivalent local tables:

- enrollment;
- outpatient services;
- inpatient admissions;
- facility claims, if separate;
- pharmacy claims;
- procedure table, if separate;
- diagnosis table, if diagnoses are normalized out of claim rows;
- enrollment demographics, if separate from enrollment spells.

For each module, provide:

- local table or file name;
- year coverage;
- row grain;
- whether records are line-level, claim-level, spell-level, or person-year-level;
- join keys needed to connect related files.

## 3. Common Identifiers and Time Fields

Provide:

- enrollee ID field name;
- family or subscriber ID field name, if needed;
- claim ID field name, if available;
- admission ID field name, if available;
- service start date;
- service end date;
- pharmacy fill date;
- enrollment start date;
- enrollment end date;
- calendar year field;
- month field, if present.

For every date field, specify:

- storage type: date, string, integer, numeric;
- format, if string;
- origin, if integer. MarketScan extracts often use SAS-style days since `1960-01-01`;
- whether date fields can be missing or partially populated.

## 4. Enrollment and Demographics

Provide field names and code meanings for:

- enrollee ID;
- enrollment start date;
- enrollment end date;
- pharmacy benefit flag;
- medical benefit flag;
- age;
- date of birth or birth year, if age is not directly available;
- sex;
- region;
- plan type;
- employer, plan, or payer identifiers if available and permitted;
- Medicare/COB flags if relevant;
- data-year membership fields.

Clarify:

- what values mean active pharmacy coverage;
- what values mean active medical coverage;
- whether enrollment is recorded as monthly indicators, date spans, or annual records;
- whether adjacent enrollment spans should be merged;
- whether gaps of 0 or 1 day are considered continuous.

## 5. Pharmacy Claims

Provide field names for:

- enrollee ID;
- fill date;
- NDC;
- days supply;
- quantity;
- allowed amount;
- plan paid;
- copay;
- coinsurance;
- deductible;
- total patient pay, if available;
- claim status or reversal indicator, if available;
- mail order or days-supply type, if available;
- therapeutic class fields, if present.

Clarify:

- whether NDC is numeric or character;
- whether NDC is 10-digit, 11-digit, hyphenated, or mixed;
- whether leading zeros are preserved;
- whether days supply can be 0, missing, negative, or greater than 365;
- how duplicate fills and reversals should be handled;
- whether costs are dollars or cents;
- whether negative costs are possible and what they mean.

## 6. Medical Claims

Provide field names for:

- enrollee ID;
- service start date;
- service end date;
- claim ID;
- claim line ID, if present;
- inpatient/outpatient indicator;
- admission/discharge dates, if available;
- place of service;
- revenue code;
- bill type;
- diagnosis-related group, if available;
- diagnosis fields;
- procedure fields;
- procedure coding system, if available;
- allowed amount;
- plan paid;
- copay;
- coinsurance;
- deductible;
- total patient pay, if available;
- claim status or reversal indicator, if available.

Clarify:

- how to identify inpatient admissions;
- how to identify ED visits;
- how to identify outpatient/office visits;
- whether facility and professional claims are separate;
- whether multiple lines belong to the same claim or encounter;
- how to aggregate spending without double counting.

## 7. Diagnosis and Procedure Codes

Provide:

- diagnosis field names in order, such as `dx1`, `dx2`, `dx3`;
- procedure field names in order;
- diagnosis coding system indicators, if present;
- procedure coding system indicators, if present;
- ICD-9 and ICD-10 transition handling;
- whether codes include decimals;
- whether codes are uppercase, lowercase, padded, or mixed.

Needed code groups:

- diabetes;
- obesity;
- chronic kidney disease;
- cardiovascular disease or ASCVD;
- heart failure;
- hypertension;
- dyslipidemia;
- sleep apnea;
- liver disease;
- depression/anxiety;
- substance use;
- diabetic complications;
- GI adverse-event proxies;
- pancreatitis;
- gallbladder disease;
- hypoglycemia;
- hyperglycemia;
- diabetic ketoacidosis;
- CKD acute events;
- CVD acute events;
- Elixhauser groups, if available;
- Charlson/NCI-style groups, if available.

For each code group, provide:

- file path under the code-list root;
- coding system: ICD-9-CM, ICD-10-CM, CPT, HCPCS, revenue code, NDC;
- columns in the code-list file;
- whether exact matching or prefix matching is intended;
- whether the code list is validated or exploratory.

## 8. Drug Code Lists

Provide NDC code-list files for:

- GLP-1 receptor agonists;
- tirzepatide, with a flag for whether to include it in the GLP-1-like class;
- DPP-4 inhibitors;
- metformin;
- insulin;
- SGLT2 inhibitors;
- sulfonylureas;
- TZDs;
- other diabetes medications, if included.

Each drug code-list file should include at least:

- `NDC11`;
- generic ingredient name, if available;
- brand name, if available;
- drug class;
- start/end market availability dates, if available;
- source/provenance.

NDC matching should use normalized 11-digit strings. Do not hard-code NDCs in scripts.

## 9. Cohort Definition Parameters

Confirm or edit these default parameters:

- data years: 2017 through 2023;
- primary index start: `2018-01-01`;
- primary index end: `2022-12-31`;
- baseline months: 12;
- follow-up months: 12;
- event-month range: `-12` through `+12`;
- minimum age: 18;
- maximum age: 64;
- GLP-1 washout: 365 days;
- DPP-4 pre-index lookback: 180 days;
- DPP-4 pre-index grace period: 60 days;
- replacement assessment window: 120 days;
- DPP-4 post-index grace period: 30 days;
- transition overlap allowed: 30 days;
- primary switch category: `clean_replacement`;
- require continuous medical enrollment: yes/no;
- require continuous pharmacy enrollment: yes/no.

The primary definition is a clean replacement switch:

- first qualifying GLP-1 fill after the washout period;
- evidence of DPP-4 use before index;
- DPP-4 coverage active at index or ending within the configured grace period;
- no meaningful post-index DPP-4 continuation after DPP-4 runout plus grace.

## 10. Coverage Construction Rules

Confirm:

- stockpiling enabled or disabled;
- maximum carryover days;
- whether early refills extend coverage;
- whether overlapping fills in the same class should be merged;
- whether coverage is capped at observation-window boundaries;
- monthly coverage measure, such as share of days covered;
- grace days for active supply;
- handling of days supply greater than 365.

The default target monthly variables include:

- active DPP-4 coverage share;
- active GLP-1 coverage share;
- active metformin coverage share;
- active insulin coverage share;
- active SGLT2 coverage share;
- active sulfonylurea coverage share;
- active TZD coverage share;
- fill indicators by class;
- days supply filled by class;
- discontinuation, switch-back, and add-on/overlap flags.

## 11. Spending and Financial Burden

Provide field definitions for pharmacy and medical:

- allowed amount;
- plan paid;
- copay;
- coinsurance;
- deductible;
- total patient pay, if available.

Clarify:

- dollars vs cents;
- whether amounts are line-level or claim-level;
- whether reversals or adjustments appear;
- whether negative values should be retained, netted, or excluded;
- whether `patient_pay` is trusted as total OOP;
- whether `copay + coinsurance + deductible` should be the primary OOP definition;
- whether missing cost fields mean zero or unknown.

Default OOP formula:

```text
patient_oop = copay + coinsurance + deductible
```

If a trusted patient-pay field exists, compare it to the component sum and write QC discrepancies.

## 12. Utilization and Outcome Definitions

Provide metadata to identify:

- inpatient admissions;
- ED visits;
- outpatient visits;
- office visits;
- total medical spending;
- total pharmacy spending;
- GLP-1 pharmacy spending;
- non-GLP spending;
- diabetes-drug spending excluding GLP-1;
- GI events;
- pancreatitis/gallbladder events;
- hypoglycemia/hyperglycemia/DKA;
- acute CKD/CVD events, if included.

For each utilization or outcome measure, specify:

- source module;
- diagnosis, procedure, place-of-service, revenue-code, or claim-type rule;
- encounter de-duplication key;
- monthly aggregation rule.

## 13. Output and QC Requirements

Target primary output:

```text
person_month_state_dpp4_to_glp1
```

Target grain:

```text
one row per enrollee_id_hash x episode_id x event_month
```

Required companion outputs:

- cohort waterfall table;
- run manifest table;
- schema validation report;
- missingness summaries;
- event-time row counts;
- treatment-state summaries;
- OOP sanity checks;
- stage-level logs without patient-level details.

Do not write rare-cell tables or patient-level examples into logs intended for AI review.

## 14. HPC Execution Metadata

Provide:

- Slurm account;
- Slurm partition;
- number of shards;
- shard key;
- CPUs per task;
- memory per task;
- wall time;
- Python or R module commands;
- conda or virtualenv activation commands;
- scratch path, if needed;
- restart/overwrite policy.

All production stages should support:

```text
--config
--shard-id
--n-shards
--year
--overwrite
```

## 15. Minimal Metadata Needed for the Existing R Prototype

If the next task is only to run or refactor `01_build_glp1_pool.R`, provide:

- raw 2022 data directory;
- work/output directory;
- pharmacy shard pattern;
- enrollment shard pattern;
- pharmacy column names for enrollee ID, fill date, NDC, days supply;
- enrollment column names for enrollee ID, start date, end date, pharmacy benefit flag;
- pharmacy benefit active value;
- date encoding;
- GLP-1 NDC11 file path;
- DuckDB memory and thread limits appropriate for the HPC node.

