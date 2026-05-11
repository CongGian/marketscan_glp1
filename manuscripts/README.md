# Manuscript Rendering

The short DPP-4 to GLP-1-like switcher paper is generated from aggregate Stage
08 CSVs only.

Preferred DOCX render on Quartz:

```bash
cd /N/project/SCIPE/tgian
module load pandoc/3.1.10
Rscript scripts/render_short_paper.R --format docx
```

The default output is:

```text
/N/project/mscan_trial/trial_users/tgian/marketscan_glp1/outputs/dpp4_to_glp1/manuscript/dpp4_glp1_short_paper.docx
```

PDF rendering requires a LaTeX-capable environment. If LaTeX is not available on
the cluster, render DOCX first and convert it to PDF in an approved local
environment.

The source file is `manuscripts/dpp4_glp1_short_paper.Rmd`.
