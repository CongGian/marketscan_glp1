#!/bin/bash
#SBATCH --job-name=mscan_stage03_enroll
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#SBATCH --time=04:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH -A staff
set -euo pipefail

# Usage:
#   sbatch slurm/run_stage_03_enrollment.sbatch
#
# This job scans MarketScan enrollment detail T files for Stage 02 candidate
# ENROLIDs and writes restricted enrollment flags. Run it only inside an
# approved MarketScan workspace.

PROJECT_ROOT="${PROJECT_ROOT:-${SLURM_SUBMIT_DIR:-$(pwd)}}"
RESTRICTED_ROOT="${RESTRICTED_ROOT:-/PATH/TO/RESTRICTED_WORKSPACE}"
CONFIG="${CONFIG:-${PROJECT_ROOT}/config/config_template.yaml}"
THREADS="${SLURM_CPUS_PER_TASK:-8}"
MEMORY_LIMIT="${MEMORY_LIMIT:-64GB}"

CANDIDATE_FILE="${CANDIDATE_FILE:-${RESTRICTED_ROOT}/derived/switch_candidates/dpp4_to_glp1_switch_candidates.parquet}"
OUT_FILE="${OUT_FILE:-${RESTRICTED_ROOT}/derived/enrollment/dpp4_to_glp1_switch_candidates_enrollment.parquet}"
QC_FILE="${QC_FILE:-${RESTRICTED_ROOT}/outputs/dpp4_to_glp1/qc/stage03_enrollment_counts.csv}"
TEMP_DIR="${TEMP_DIR:-${RESTRICTED_ROOT}/tmp}"
DB_PATH="${DB_PATH:-:memory:}"

cd "${PROJECT_ROOT}"
mkdir -p \
  "${RESTRICTED_ROOT}/logs/dpp4_to_glp1" \
  "$(dirname "${OUT_FILE}")" \
  "$(dirname "${QC_FILE}")" \
  "${TEMP_DIR}" \
  "${RESTRICTED_ROOT}/duckdb"

echo "[$(date)] Starting Stage 03 enrollment extraction on ${HOSTNAME}"
echo "PROJECT_ROOT=${PROJECT_ROOT}"
echo "RESTRICTED_ROOT=${RESTRICTED_ROOT}"
echo "CONFIG=${CONFIG}"
echo "CANDIDATE_FILE=${CANDIDATE_FILE}"
echo "OUT_FILE=${OUT_FILE}"
echo "QC_FILE=${QC_FILE}"
echo "THREADS=${THREADS}"
echo "MEMORY_LIMIT=${MEMORY_LIMIT}"

Rscript scripts/stage_03_extract_enrollment.R \
  --config "${CONFIG}" \
  --candidate-file "${CANDIDATE_FILE}" \
  --years "2017:2023" \
  --out-file "${OUT_FILE}" \
  --qc-file "${QC_FILE}" \
  --threads "${THREADS}" \
  --memory "${MEMORY_LIMIT}" \
  --temp-dir "${TEMP_DIR}" \
  --db "${DB_PATH}"

echo "[$(date)] Completed Stage 03 enrollment extraction"
