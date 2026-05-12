#!/bin/bash
#SBATCH --job-name=mscan_stage07_final
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#SBATCH --time=01:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH -A staff
set -euo pipefail

# Usage:
#   sbatch slurm/run_stage_07_final_sample.sbatch
#
# This job reads the Stage 06 person-month output, writes the final restricted
# analytic parquet, and creates aggregate QC/descriptive CSVs. Run it only
# inside an approved MarketScan workspace.

PROJECT_ROOT="${PROJECT_ROOT:-${SLURM_SUBMIT_DIR:-$(pwd)}}"
RESTRICTED_ROOT="${RESTRICTED_ROOT:-/PATH/TO/RESTRICTED_WORKSPACE}"
CONFIG="${CONFIG:-${PROJECT_ROOT}/config/config_template.yaml}"
THREADS="${SLURM_CPUS_PER_TASK:-4}"
MEMORY_LIMIT="${MEMORY_LIMIT:-32GB}"
CELL_SUPPRESSION_THRESHOLD="${CELL_SUPPRESSION_THRESHOLD:-11}"

INPUT_FILE="${INPUT_FILE:-${RESTRICTED_ROOT}/derived/person_month/person_month_with_pharmacy_medical.parquet}"
OUT_FILE="${OUT_FILE:-${RESTRICTED_ROOT}/outputs/dpp4_to_glp1/person_month_dpp4_to_glp1_switchers.parquet}"
QC_FILE="${QC_FILE:-${RESTRICTED_ROOT}/outputs/dpp4_to_glp1/qc/stage07_final_sample_counts.csv}"
BASELINE_DESCRIPTIVES="${BASELINE_DESCRIPTIVES:-${RESTRICTED_ROOT}/outputs/dpp4_to_glp1/descriptives/stage07_baseline_characteristics.csv}"
PERSON_MONTH_DESCRIPTIVES="${PERSON_MONTH_DESCRIPTIVES:-${RESTRICTED_ROOT}/outputs/dpp4_to_glp1/descriptives/stage07_person_month_descriptives.csv}"
TEMP_DIR="${TEMP_DIR:-${RESTRICTED_ROOT}/tmp}"
DB_PATH="${DB_PATH:-:memory:}"

cd "${PROJECT_ROOT}"
mkdir -p \
  "${RESTRICTED_ROOT}/logs/dpp4_to_glp1" \
  "$(dirname "${OUT_FILE}")" \
  "$(dirname "${QC_FILE}")" \
  "$(dirname "${BASELINE_DESCRIPTIVES}")" \
  "$(dirname "${PERSON_MONTH_DESCRIPTIVES}")" \
  "${TEMP_DIR}" \
  "${RESTRICTED_ROOT}/duckdb"

echo "[$(date)] Starting Stage 07 final sample assembly on ${HOSTNAME}"
echo "PROJECT_ROOT=${PROJECT_ROOT}"
echo "RESTRICTED_ROOT=${RESTRICTED_ROOT}"
echo "CONFIG=${CONFIG}"
echo "INPUT_FILE=${INPUT_FILE}"
echo "OUT_FILE=${OUT_FILE}"
echo "QC_FILE=${QC_FILE}"
echo "BASELINE_DESCRIPTIVES=${BASELINE_DESCRIPTIVES}"
echo "PERSON_MONTH_DESCRIPTIVES=${PERSON_MONTH_DESCRIPTIVES}"
echo "THREADS=${THREADS}"
echo "MEMORY_LIMIT=${MEMORY_LIMIT}"
echo "CELL_SUPPRESSION_THRESHOLD=${CELL_SUPPRESSION_THRESHOLD}"

Rscript scripts/stage_07_build_final_sample.R \
  --config "${CONFIG}" \
  --input-file "${INPUT_FILE}" \
  --out-file "${OUT_FILE}" \
  --qc-file "${QC_FILE}" \
  --baseline-descriptives "${BASELINE_DESCRIPTIVES}" \
  --person-month-descriptives "${PERSON_MONTH_DESCRIPTIVES}" \
  --threads "${THREADS}" \
  --memory "${MEMORY_LIMIT}" \
  --temp-dir "${TEMP_DIR}" \
  --db "${DB_PATH}" \
  --cell-suppression-threshold "${CELL_SUPPRESSION_THRESHOLD}"

echo "[$(date)] Completed Stage 07 final sample assembly"
