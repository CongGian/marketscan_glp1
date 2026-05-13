# Local Codex Instructions

This repository may be used with Codex on a laptop or other non-restricted
development environment. The agent must operate on source code, documentation,
public code lists, and synthetic data only.

## Hard Data Boundary

Do not read, request, generate, or commit:

- raw MarketScan data;
- derived restricted outputs;
- metadata manifests generated from restricted data;
- job logs from restricted runs;
- licensed MarketScan PDFs or codebooks;
- real row-level identifiers, dates, NDCs observed in claims, diagnosis codes
  observed in claims, or costs;
- local HPC paths or user-specific restricted paths;
- empirical manuscript drafts or figures based on restricted output unless the
  user explicitly says they are cleared for sharing.

Use placeholders such as `/PATH/TO/RESTRICTED_WORKSPACE` in committed files.
Real paths are supplied only by the human analyst inside the approved HPC
workspace.

## Development Rules

- Use synthetic data and tests for all local validation.
- Prefer generic, reusable code over project-path-specific scripts.
- Keep `config/config_template.yaml` sanitized.
- Keep `config/local_config.yaml` untracked.
- Do not use `git add .`; stage explicit source files.
- Do not add files from `outputs/`, `logs/`, `metadata/`, `duckdb/`, `raw/`,
  `derived/`, or `data/`.

## Current Priority

The next code-generation task is to design a generic diabetes medication
transition atlas. It should compare candidate starting classes before GLP-1
initiation, including metformin, DPP-4 inhibitors, SGLT2 inhibitors,
sulfonylureas, and insulin.

The transition atlas should report, using restricted data only when run later by
the human analyst on HPC:

- baseline users by starting class;
- GLP-1 initiators by starting class;
- clean replacement, continuation, add-on/overlap, discontinuation, and
  switch-back rates;
- baseline clinical burden;
- medication-state trajectories;
- cost decomposition separating GLP-1-like pharmacy, non-GLP-1 pharmacy, and
  medical spending.

Local Codex should implement this using synthetic fixtures and tests only.
