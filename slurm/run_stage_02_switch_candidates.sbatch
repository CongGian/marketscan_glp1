#!/bin/bash
#SBATCH --job-name=mscan_stage02_switch
#SBATCH --output=/N/project/mscan_trial/trial_users/tgian/marketscan_glp1/logs/dpp4_to_glp1/%x_%j.out
#SBATCH --error=/N/project/mscan_trial/trial_users/tgian/marketscan_glp1/logs/dpp4_to_glp1/%x_%j.err
#SBATCH --time=06:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH -A staff
set -euo pipefail

# Usage:
#   sbatch slurm/run_stage_02_switch_candidates.sbatch
#
# This job scans Stage 01 restricted derived pharmacy files and writes a
# restricted switch-candidate episode table. Run it only inside an approved
# MarketScan workspace.

PROJECT_ROOT="${PROJECT_ROOT:-/N/project/SCIPE/tgian}"
RESTRICTED_ROOT="${RESTRICTED_ROOT:-/N/project/mscan_trial/trial_users/tgian/marketscan_glp1}"
CONFIG="${CONFIG:-${PROJECT_ROOT}/config/config_template.yaml}"
THREADS="${SLURM_CPUS_PER_TASK:-8}"
MEMORY_LIMIT="${MEMORY_LIMIT:-64GB}"

INPUT_DIR="${INPUT_DIR:-${RESTRICTED_ROOT}/derived/drug_fills}"
OUT_FILE="${OUT_FILE:-${RESTRICTED_ROOT}/derived/switch_candidates/dpp4_to_glp1_switch_candidates.parquet}"
QC_FILE="${QC_FILE:-${RESTRICTED_ROOT}/outputs/dpp4_to_glp1/qc/stage02_switch_candidate_counts.csv}"
TEMP_DIR="${TEMP_DIR:-${RESTRICTED_ROOT}/tmp}"
DB_PATH="${DB_PATH:-:memory:}"

cd "${PROJECT_ROOT}"
mkdir -p \
  "${RESTRICTED_ROOT}/logs/dpp4_to_glp1" \
  "$(dirname "${OUT_FILE}")" \
  "$(dirname "${QC_FILE}")" \
  "${TEMP_DIR}" \
  "${RESTRICTED_ROOT}/duckdb"

echo "[$(date)] Starting Stage 02 switch candidate extraction on ${HOSTNAME}"
echo "PROJECT_ROOT=${PROJECT_ROOT}"
echo "RESTRICTED_ROOT=${RESTRICTED_ROOT}"
echo "CONFIG=${CONFIG}"
echo "INPUT_DIR=${INPUT_DIR}"
echo "OUT_FILE=${OUT_FILE}"
echo "QC_FILE=${QC_FILE}"
echo "THREADS=${THREADS}"
echo "MEMORY_LIMIT=${MEMORY_LIMIT}"

Rscript scripts/stage_02_extract_switch_candidates.R \
  --config "${CONFIG}" \
  --input-dir "${INPUT_DIR}" \
  --years "2017:2023" \
  --out-file "${OUT_FILE}" \
  --qc-file "${QC_FILE}" \
  --threads "${THREADS}" \
  --memory "${MEMORY_LIMIT}" \
  --temp-dir "${TEMP_DIR}" \
  --db "${DB_PATH}"

echo "[$(date)] Completed Stage 02 switch candidate extraction"
