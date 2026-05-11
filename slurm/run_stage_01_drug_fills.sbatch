#!/bin/bash
#SBATCH --job-name=mscan_stage01_drugs
#SBATCH --output=/N/project/mscan_trial/trial_users/tgian/marketscan_glp1/logs/dpp4_to_glp1/%x_%A_%a.out
#SBATCH --error=/N/project/mscan_trial/trial_users/tgian/marketscan_glp1/logs/dpp4_to_glp1/%x_%A_%a.err
#SBATCH --time=04:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --array=0-6
#SBATCH -A staff
set -euo pipefail

# Usage:
#   sbatch slurm/run_stage_01_drug_fills.sbatch
#
# Optional overrides:
#   CONFIG=/path/to/config.yaml OUT_DIR=/approved/restricted/derived/drug_fills sbatch slurm/run_stage_01_drug_fills.sbatch
#   YEAR=2021 sbatch --array=0-0 slurm/run_stage_01_drug_fills.sbatch
#   YEARS="2020 2021" sbatch --array=0-1 slurm/run_stage_01_drug_fills.sbatch
#
# This job scans row-level MarketScan pharmacy claims and writes a restricted
# derived parquet. Run it only inside an approved MarketScan workspace.

PROJECT_ROOT="${PROJECT_ROOT:-/N/project/SCIPE/tgian}"
RESTRICTED_ROOT="${RESTRICTED_ROOT:-/N/project/mscan_trial/trial_users/tgian/marketscan_glp1}"
CONFIG="${CONFIG:-${PROJECT_ROOT}/config/config_template.yaml}"
OUT_DIR="${OUT_DIR:-${RESTRICTED_ROOT}/derived/drug_fills}"
THREADS="${SLURM_CPUS_PER_TASK:-4}"
MEMORY_LIMIT="${MEMORY_LIMIT:-32GB}"
DEFAULT_YEARS="2017 2018 2019 2020 2021 2022 2023"

if [[ -n "${YEAR:-}" ]]; then
  SELECTED_YEAR="${YEAR}"
else
  YEAR_LIST="${YEARS:-${DEFAULT_YEARS}}"
  YEAR_LIST="${YEAR_LIST//,/ }"
  IFS=' ' read -r -a YEAR_VALUES <<< "${YEAR_LIST}"
  TASK_ID="${SLURM_ARRAY_TASK_ID:-0}"
  if ! [[ "${TASK_ID}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: SLURM_ARRAY_TASK_ID must be a non-negative integer, got: ${TASK_ID}" >&2
    exit 2
  fi
  if (( TASK_ID >= ${#YEAR_VALUES[@]} )); then
    echo "ERROR: array task ${TASK_ID} has no matching year in YEARS='${YEAR_LIST}'." >&2
    exit 2
  fi
  SELECTED_YEAR="${YEAR_VALUES[${TASK_ID}]}"
fi

cd "${PROJECT_ROOT}"
mkdir -p "${RESTRICTED_ROOT}/logs/dpp4_to_glp1" "${OUT_DIR}" "${RESTRICTED_ROOT}/duckdb" "${RESTRICTED_ROOT}/tmp"

echo "[$(date)] Starting Stage 01 diabetes-drug fill extraction on ${HOSTNAME}"
echo "PROJECT_ROOT=${PROJECT_ROOT}"
echo "RESTRICTED_ROOT=${RESTRICTED_ROOT}"
echo "CONFIG=${CONFIG}"
echo "YEAR=${SELECTED_YEAR}"
echo "OUT_DIR=${OUT_DIR}"
echo "THREADS=${THREADS}"
echo "MEMORY_LIMIT=${MEMORY_LIMIT}"

Rscript scripts/stage_01_extract_drug_fills.R \
  --config "${CONFIG}" \
  --years "${SELECTED_YEAR}" \
  --out-file "${OUT_DIR}/diabetes_drug_fills_${SELECTED_YEAR}.parquet" \
  --threads "${THREADS}" \
  --memory "${MEMORY_LIMIT}"

echo "[$(date)] Completed Stage 01 for ${SELECTED_YEAR}"
