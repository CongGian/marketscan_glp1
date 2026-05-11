# Overleaf Files

Upload `dpp4_glp1_short_paper_overleaf.tex` to Overleaf.

The Stage 08 figures are located here on the cluster:

```text
/N/project/mscan_trial/trial_users/tgian/marketscan_glp1/outputs/dpp4_to_glp1/figures
```

Upload these PNGs into an Overleaf folder named `figures/`:

- `baseline_condition_prevalence.png`
- `event_time_medication_rates.png`
- `treatment_state_event_time.png`
- `event_time_utilization_rates.png`
- `event_time_oop_spending.png`
- `multimorbidity_burden.png`

To stage the Overleaf figure folder locally from the aggregate figure outputs:

```bash
cd /N/project/SCIPE/tgian
mkdir -p manuscripts/overleaf/figures
cp /N/project/mscan_trial/trial_users/tgian/marketscan_glp1/outputs/dpp4_to_glp1/figures/*.png manuscripts/overleaf/figures/
```

The LaTeX source uses the Lato package:

```latex
\usepackage[default]{lato}
```

The broad all-GLP-1-like denominator for the revised waterfall comes from this
aggregate file:

```text
/N/project/mscan_trial/trial_users/tgian/marketscan_glp1/outputs/dpp4_to_glp1/figures/data/glp1_user_waterfall_by_period.csv
```

To regenerate it inside the restricted workspace:

```bash
cd /N/project/SCIPE/tgian
Rscript scripts/stage_08_glp1_waterfall.R
```
