#!/bin/bash
#SBATCH --job-name=mscan_stage04_spine
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#SBATCH --time=01:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH -A staff
set -euo pipefail

# Usage:
#   sbatch slurm/run_stage_04_person_month_spine.sbatch
#
# This job reads Stage 03 restricted enrollment output and writes the restricted
# enrolled clean-replacement person-month spine. Run it only inside an approved
# MarketScan workspace.

PROJECT_ROOT="${PROJECT_ROOT:-${SLURM_SUBMIT_DIR:-$(pwd)}}"
RESTRICTED_ROOT="${RESTRICTED_ROOT:-/PATH/TO/RESTRICTED_WORKSPACE}"
CONFIG="${CONFIG:-${PROJECT_ROOT}/config/config_template.yaml}"
THREADS="${SLURM_CPUS_PER_TASK:-4}"
MEMORY_LIMIT="${MEMORY_LIMIT:-32GB}"

INPUT_FILE="${INPUT_FILE:-${RESTRICTED_ROOT}/derived/enrollment/dpp4_to_glp1_switch_candidates_enrollment.parquet}"
OUT_FILE="${OUT_FILE:-${RESTRICTED_ROOT}/derived/person_month/person_month_spine_clean_replacement.parquet}"
QC_FILE="${QC_FILE:-${RESTRICTED_ROOT}/outputs/dpp4_to_glp1/qc/stage04_person_month_spine_counts.csv}"
DESCRIPTIVE_FILE="${DESCRIPTIVE_FILE:-${RESTRICTED_ROOT}/outputs/dpp4_to_glp1/descriptives/stage04_enrolled_clean_replacement_description.csv}"
TEMP_DIR="${TEMP_DIR:-${RESTRICTED_ROOT}/tmp}"
DB_PATH="${DB_PATH:-:memory:}"

cd "${PROJECT_ROOT}"
mkdir -p \
  "${RESTRICTED_ROOT}/logs/dpp4_to_glp1" \
  "$(dirname "${OUT_FILE}")" \
  "$(dirname "${QC_FILE}")" \
  "$(dirname "${DESCRIPTIVE_FILE}")" \
  "${TEMP_DIR}" \
  "${RESTRICTED_ROOT}/duckdb"

echo "[$(date)] Starting Stage 04 person-month spine build on ${HOSTNAME}"
echo "PROJECT_ROOT=${PROJECT_ROOT}"
echo "RESTRICTED_ROOT=${RESTRICTED_ROOT}"
echo "CONFIG=${CONFIG}"
echo "INPUT_FILE=${INPUT_FILE}"
echo "OUT_FILE=${OUT_FILE}"
echo "QC_FILE=${QC_FILE}"
echo "DESCRIPTIVE_FILE=${DESCRIPTIVE_FILE}"
echo "THREADS=${THREADS}"
echo "MEMORY_LIMIT=${MEMORY_LIMIT}"

Rscript scripts/stage_04_build_person_month_spine.R \
  --config "${CONFIG}" \
  --input-file "${INPUT_FILE}" \
  --out-file "${OUT_FILE}" \
  --qc-file "${QC_FILE}" \
  --descriptive-file "${DESCRIPTIVE_FILE}" \
  --threads "${THREADS}" \
  --memory "${MEMORY_LIMIT}" \
  --temp-dir "${TEMP_DIR}" \
  --db "${DB_PATH}"

echo "[$(date)] Completed Stage 04 person-month spine build"
