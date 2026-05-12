#!/bin/bash
#SBATCH --job-name=mscan_stage06_med
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#SBATCH --time=06:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH -A staff
set -euo pipefail

# Usage:
#   sbatch slurm/run_stage_06_medical_features.sbatch
#
# This job reads Stage 05 person-month output and scans MarketScan O/I files for
# sample ENROLIDs to write restricted medical features. Run it only inside an
# approved MarketScan workspace.

PROJECT_ROOT="${PROJECT_ROOT:-${SLURM_SUBMIT_DIR:-$(pwd)}}"
RESTRICTED_ROOT="${RESTRICTED_ROOT:-/PATH/TO/RESTRICTED_WORKSPACE}"
CONFIG="${CONFIG:-${PROJECT_ROOT}/config/config_template.yaml}"
THREADS="${SLURM_CPUS_PER_TASK:-8}"
MEMORY_LIMIT="${MEMORY_LIMIT:-64GB}"

INPUT_FILE="${INPUT_FILE:-${RESTRICTED_ROOT}/derived/person_month/person_month_with_pharmacy.parquet}"
OUT_FILE="${OUT_FILE:-${RESTRICTED_ROOT}/derived/person_month/person_month_with_pharmacy_medical.parquet}"
QC_FILE="${QC_FILE:-${RESTRICTED_ROOT}/outputs/dpp4_to_glp1/qc/stage06_medical_feature_counts.csv}"
TEMP_DIR="${TEMP_DIR:-${RESTRICTED_ROOT}/tmp}"
DB_PATH="${DB_PATH:-:memory:}"

cd "${PROJECT_ROOT}"
mkdir -p \
  "${RESTRICTED_ROOT}/logs/dpp4_to_glp1" \
  "$(dirname "${OUT_FILE}")" \
  "$(dirname "${QC_FILE}")" \
  "${TEMP_DIR}" \
  "${RESTRICTED_ROOT}/duckdb"

echo "[$(date)] Starting Stage 06 medical feature build on ${HOSTNAME}"
echo "PROJECT_ROOT=${PROJECT_ROOT}"
echo "RESTRICTED_ROOT=${RESTRICTED_ROOT}"
echo "CONFIG=${CONFIG}"
echo "INPUT_FILE=${INPUT_FILE}"
echo "OUT_FILE=${OUT_FILE}"
echo "QC_FILE=${QC_FILE}"
echo "THREADS=${THREADS}"
echo "MEMORY_LIMIT=${MEMORY_LIMIT}"

Rscript scripts/stage_06_add_medical_features.R \
  --config "${CONFIG}" \
  --input-file "${INPUT_FILE}" \
  --years "2017:2023" \
  --out-file "${OUT_FILE}" \
  --qc-file "${QC_FILE}" \
  --threads "${THREADS}" \
  --memory "${MEMORY_LIMIT}" \
  --temp-dir "${TEMP_DIR}" \
  --db "${DB_PATH}"

echo "[$(date)] Completed Stage 06 medical feature build"
