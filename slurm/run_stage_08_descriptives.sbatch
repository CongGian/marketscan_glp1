#!/bin/bash
#SBATCH --job-name=mscan_stage08_desc
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#SBATCH --time=01:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH -A staff
set -euo pipefail

# Usage:
#   sbatch slurm/run_stage_08_descriptives.sbatch
#
# This job reads the final restricted Stage 07 person-month parquet and writes
# aggregate figure-ready CSVs plus optional aggregate-only figures.

PROJECT_ROOT="${PROJECT_ROOT:-${SLURM_SUBMIT_DIR:-$(pwd)}}"
RESTRICTED_ROOT="${RESTRICTED_ROOT:-/PATH/TO/RESTRICTED_WORKSPACE}"
CONFIG="${CONFIG:-${PROJECT_ROOT}/config/config_template.yaml}"
THREADS="${SLURM_CPUS_PER_TASK:-4}"
MEMORY_LIMIT="${MEMORY_LIMIT:-32GB}"
CELL_SUPPRESSION_THRESHOLD="${CELL_SUPPRESSION_THRESHOLD:-11}"
MAKE_FIGURES="${MAKE_FIGURES:-true}"
FIGURE_FORMATS="${FIGURE_FORMATS:-png}"

INPUT_FILE="${INPUT_FILE:-${RESTRICTED_ROOT}/outputs/dpp4_to_glp1/person_month_dpp4_to_glp1_switchers.parquet}"
OUTPUT_DIR="${OUTPUT_DIR:-${RESTRICTED_ROOT}/outputs/dpp4_to_glp1/figures/data}"
FIGURE_DIR="${FIGURE_DIR:-${RESTRICTED_ROOT}/outputs/dpp4_to_glp1/figures}"
TEMP_DIR="${TEMP_DIR:-${RESTRICTED_ROOT}/tmp}"
DB_PATH="${DB_PATH:-:memory:}"

QC_STAGE02="${QC_STAGE02:-${RESTRICTED_ROOT}/outputs/dpp4_to_glp1/qc/stage02_switch_candidate_counts.csv}"
QC_STAGE03="${QC_STAGE03:-${RESTRICTED_ROOT}/outputs/dpp4_to_glp1/qc/stage03_enrollment_counts.csv}"
QC_STAGE04="${QC_STAGE04:-${RESTRICTED_ROOT}/outputs/dpp4_to_glp1/qc/stage04_person_month_spine_counts.csv}"
QC_STAGE05="${QC_STAGE05:-${RESTRICTED_ROOT}/outputs/dpp4_to_glp1/qc/stage05_pharmacy_feature_counts.csv}"
QC_STAGE06="${QC_STAGE06:-${RESTRICTED_ROOT}/outputs/dpp4_to_glp1/qc/stage06_medical_feature_counts.csv}"
QC_STAGE07="${QC_STAGE07:-${RESTRICTED_ROOT}/outputs/dpp4_to_glp1/qc/stage07_final_sample_counts.csv}"

cd "${PROJECT_ROOT}"
mkdir -p \
  "${RESTRICTED_ROOT}/logs/dpp4_to_glp1" \
  "${OUTPUT_DIR}" \
  "${FIGURE_DIR}" \
  "${TEMP_DIR}" \
  "${RESTRICTED_ROOT}/duckdb"

echo "[$(date)] Starting Stage 08 aggregate descriptives on ${HOSTNAME}"
echo "PROJECT_ROOT=${PROJECT_ROOT}"
echo "RESTRICTED_ROOT=${RESTRICTED_ROOT}"
echo "CONFIG=${CONFIG}"
echo "INPUT_FILE=${INPUT_FILE}"
echo "OUTPUT_DIR=${OUTPUT_DIR}"
echo "FIGURE_DIR=${FIGURE_DIR}"
echo "THREADS=${THREADS}"
echo "MEMORY_LIMIT=${MEMORY_LIMIT}"
echo "CELL_SUPPRESSION_THRESHOLD=${CELL_SUPPRESSION_THRESHOLD}"
echo "MAKE_FIGURES=${MAKE_FIGURES}"

Rscript scripts/stage_08_build_descriptive_tables.R \
  --config "${CONFIG}" \
  --input-file "${INPUT_FILE}" \
  --output-dir "${OUTPUT_DIR}" \
  --qc-stage02 "${QC_STAGE02}" \
  --qc-stage03 "${QC_STAGE03}" \
  --qc-stage04 "${QC_STAGE04}" \
  --qc-stage05 "${QC_STAGE05}" \
  --qc-stage06 "${QC_STAGE06}" \
  --qc-stage07 "${QC_STAGE07}" \
  --threads "${THREADS}" \
  --memory "${MEMORY_LIMIT}" \
  --temp-dir "${TEMP_DIR}" \
  --db "${DB_PATH}" \
  --cell-suppression-threshold "${CELL_SUPPRESSION_THRESHOLD}"

if [[ "${MAKE_FIGURES}" == "true" || "${MAKE_FIGURES}" == "1" || "${MAKE_FIGURES}" == "yes" ]]; then
  Rscript scripts/stage_08_make_figures.R \
    --data-dir "${OUTPUT_DIR}" \
    --figure-dir "${FIGURE_DIR}" \
    --formats "${FIGURE_FORMATS}"
fi

echo "[$(date)] Completed Stage 08 aggregate descriptives"
