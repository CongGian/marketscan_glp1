# Stage 08 Descriptive Tables and Figures

Stage 08 creates aggregate, figure-ready outputs for the DPP-4 to GLP-1-like
switcher paper. It reads the final restricted Stage 07 person-month parquet and
writes CSV summaries and optional figures. It does not write row-level CSVs.

## Data Boundary

Run Stage 08 only inside the approved MarketScan workspace. The input parquet is
restricted derived row-level data. The outputs are aggregate summaries intended
for analyst review. Do not paste row-level records, enrollee IDs, dates, claim
IDs, NDCs observed in claims, diagnosis codes observed in claims, or claim-line
costs into prompts or external tools.

The default output directory is:

```text
/PATH/TO/RESTRICTED_WORKSPACE/outputs/dpp4_to_glp1/figures/data
```

## Run

After Stage 07 completes:

```bash
cd /PATH/TO/REPO
sbatch slurm/run_stage_08_descriptives.sbatch
```

To write only aggregate CSVs and skip figure rendering:

```bash
cd /PATH/TO/REPO
MAKE_FIGURES=false sbatch slurm/run_stage_08_descriptives.sbatch
```

The plotting step requires `ggplot2` in the R environment. No package
installation is performed by the scripts.

## Aggregate CSV Outputs

Stage 08 writes:

- `event_time_medication_rates.csv`: event-month medication-use rates from `drug_any_*` columns.
- `treatment_state_event_time.csv`: DPP-4 only, GLP-1-like only, both, and neither by event month.
- `event_time_utilization_rates.csv`: event-month rates for any claim, Rx fill, medical claim, outpatient, inpatient, and ED utilization when available.
- `event_time_spending_summary.csv`: event-month means and quantiles for OOP, allowed amount, and plan-paid variables.
- `event_time_spending_distribution.csv`: event-month spending distributions for total, medical, Rx, and GLP-1-like Rx variables, including all person-month and positive-spending summaries with p50/p75/p90/p95/p99.
- `event_time_spending_decomposition.csv`: event-month medical, GLP-1-like Rx, and other-Rx decomposition for allowed amount, plan-paid amount, and patient OOP.
- `baseline_condition_prevalence.csv`: episode-level baseline comorbidity prevalence.
- `baseline_comorbidity_category_prevalence.csv`: episode-level baseline comorbidity/category prevalence, with `category_set` identifying study-defined, Charlson, or Elixhauser-style category namespaces when available.
- `multimorbidity_burden.csv`: number of baseline condition flags per episode.
- `baseline_spending_utilization_summary.csv`: baseline age, utilization, and spending summaries.
- `sample_structure.csv`: final sample counts, index-year distribution, event-month counts, and duplicate-key check.
- `cohort_waterfall.csv`: sample reduction across stages using prior aggregate QC files when available.

Counts are small-cell suppressed by default when `0 < n < 11`.

`baseline_comorbidity_category_prevalence.csv` uses whatever baseline
condition/category flags are present in the Stage 07 final parquet. With the
current study-defined concept files, `category_set` is `study_defined`. If
Charlson or Elixhauser category code lists are added upstream with concept names
such as `charlson_*` or `elixhauser_*`, the same Stage 08 output will label
those rows under the corresponding `category_set`.

## Recommended Paper Tables

1. Exposure definition and analytic index table.
2. Cohort construction waterfall from switch candidates to final person-month panel.
3. Baseline demographic, enrollment, utilization, and expenditure table with medians and upper percentiles because costs and utilization are right-skewed.
4. Baseline clinical burden table using standard comorbidity categories when available, preferably Elixhauser or Charlson category indicators rather than only a score.
5. Medication-state table by baseline, index, and follow-up windows.
6. Variable inventory for causal graph and digital twin state construction.

## Recommended Figures

1. Cohort waterfall.
2. Event-time medication transition plot.
3. DPP-4/GLP-1-like treatment-state stacked plot.
4. Baseline comorbidity prevalence bar chart.
5. Event-time utilization plot.
6. Event-time patient OOP spending plot.
7. Event-time total allowed spending percentile plot to show skewed cost distributions.
8. Event-time allowed spending decomposition plot splitting medical, GLP-1-like Rx, and other Rx costs.
9. GLP-1-like Rx payer decomposition plot splitting plan-paid and patient OOP components.
10. Multimorbidity burden histogram.
11. Conceptual causal knowledge graph.
12. Digital twin patient-month state-vector schematic.

## Scripts

- `R/stage_08_descriptive_tables.R`: aggregate table builder.
- `scripts/stage_08_build_descriptive_tables.R`: command-line table wrapper.
- `R/stage_08_descriptive_plots.R`: aggregate-only plotting helpers.
- `scripts/stage_08_make_figures.R`: command-line plotting wrapper.
- `slurm/run_stage_08_descriptives.sbatch`: one-command analyst-run Slurm job.
