# Local Codex Handoff

This file summarizes the current state for a new Codex session running on a
laptop or other non-restricted development machine.

## Why The Workflow Is Moving Off HPC

The team discussed whether AI agents should run in an HPC session that has Unix
permissions to restricted MarketScan folders. The decision is to avoid that
pattern. AI agents should be used only for code generation, documentation, and
drafting in a source-only environment that has no technical access to restricted
data.

The human analyst will pull source code onto HPC and manually run Slurm jobs
inside the approved workspace. AI agents should not inspect restricted folders,
submit jobs, or read restricted outputs.

## What Is In GitHub

The repository should contain:

- R source modules;
- command-line wrappers;
- Slurm templates with placeholder paths;
- tests using synthetic data;
- public concept/code-list files;
- sanitized config templates;
- workflow documentation.

The repository should not contain restricted data, licensed MarketScan PDFs,
restricted metadata manifests, logs, derived outputs, or empirical manuscript
artifacts.

## What Happened So Far

The current pipeline builds an event-time person-month panel around diabetes
medication transitions. The first implemented use case is DPP-4 to GLP-1-like
clean replacement. Stages include drug-fill extraction, switch-candidate
classification, continuous-enrollment checks, person-month spine construction,
pharmacy features, medical features, final sample assembly, and aggregate
descriptive outputs.

Important issue: total spending around the GLP-1 index fill includes the
GLP-1-like drug price unless explicitly decomposed. Future outputs should
separate GLP-1-like pharmacy spending from non-GLP-1 pharmacy and medical
spending.

Important scientific issue: a colleague raised concerns that DPP-4 users are a
smaller and potentially more selected population than users of common first-line
or background therapies such as metformin. The next workflow should therefore
generalize beyond DPP-4 and compare multiple candidate starting drug classes.

## Next Development Task

Build a generic `transition_atlas` module using synthetic data only.

The atlas should support candidate starting classes such as:

- metformin;
- DPP-4 inhibitors;
- SGLT2 inhibitors;
- sulfonylureas;
- insulin.

For each starting class, the eventual restricted-data run should produce
aggregate summaries of:

- class-specific baseline users;
- GLP-1-like initiators;
- clean replacement rate;
- continuation rate;
- add-on/overlap rate;
- discontinuation rate;
- switch-back rate;
- baseline clinical burden;
- medication-state trajectories;
- spending decomposition with and without GLP-1-like pharmacy cost.

Do not hard-code real HPC paths. Add tests that run entirely on synthetic data.

## Positive And Negative Controls

Positive-control checks should confirm mechanically expected behavior:

- GLP-1-like fills rise at the index month;
- GLP-1-like pharmacy spending rises at the index month;
- the starting drug falls after index for clean-replacement definitions when
  clinically appropriate.

Negative-control or falsification checks should focus on measures not expected
to move mechanically because of the GLP-1 drug price:

- medical-only spending;
- non-GLP-1 pharmacy spending;
- placebo pre-index transition dates;
- unrelated acute events or unrelated medication classes, subject to clinical
  review.

Metformin may not be a clean replacement target because it is often continued as
background therapy. It may still be important as a common starting or background
class in the transition atlas.

## Safe Return To HPC

Use GitHub as source-code transport only:

```text
laptop source code -> GitHub -> HPC git pull -> human-run Slurm
```

On HPC, the analyst supplies real paths through environment variables or an
untracked local config file. Do not commit those paths.
