#!/bin/bash
#SBATCH --job-name=mscan_metadata
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#SBATCH --time=00:30:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH -A staff
set -euo pipefail

# Usage:
#   sbatch slurm/run_marketscan_metadata.sbatch
#
# Optional overrides:
#   YEARS="2017 2018 2019 2020 2021 2022 2023" sbatch slurm/run_marketscan_metadata.sbatch
#   RAW_ROOT=/path/to/parquet OUTPUT=/path/to/manifest.json sbatch slurm/run_marketscan_metadata.sbatch
#
# This job reads Parquet footers/schema metadata only. It does not scan
# MarketScan rows or export patient-level data.

PROJECT_ROOT="${PROJECT_ROOT:-${SLURM_SUBMIT_DIR:-$(pwd)}}"
RESTRICTED_ROOT="${RESTRICTED_ROOT:-/PATH/TO/RESTRICTED_WORKSPACE}"
cd "${PROJECT_ROOT}"

mkdir -p "${RESTRICTED_ROOT}/logs/metadata" "${RESTRICTED_ROOT}/metadata"

echo "[$(date)] Starting MarketScan metadata manifest on ${HOSTNAME}"
echo "PROJECT_ROOT=${PROJECT_ROOT}"
echo "RESTRICTED_ROOT=${RESTRICTED_ROOT}"
echo "YEARS=${YEARS:-2016 2017 2018 2019 2020 2021 2022 2023 2024}"
echo "RAW_ROOT=${RAW_ROOT:-/PATH/TO/RESTRICTED_MARKETSCAN_PARQUET}"
echo "OUTPUT=${OUTPUT:-${RESTRICTED_ROOT}/metadata/marketscan_metadata_manifest_all_years.json}"

tools/run_marketscan_metadata_all_years.sh

echo "[$(date)] Completed MarketScan metadata manifest"
