#!/bin/bash
#SBATCH --job-name=ms_dpp4_glp1_stage
#SBATCH --output=logs/%x_%A_%a.out
#SBATCH --error=logs/%x_%A_%a.err
#SBATCH --array=0-199
#SBATCH --time=04:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
# Optional site-specific fields:
# #SBATCH --account=<account>
# #SBATCH --partition=<partition>

set -euo pipefail

# Usage example:
#   sbatch --array=0-199 slurm_run_stage_array_template.sbatch stage_02_build_drug_episodes config/local_config.yaml 200
#
# Arguments:
#   $1 = stage name, e.g. stage_02_build_drug_episodes
#   $2 = config path
#   $3 = number of shards

STAGE=${1:?"Missing stage name"}
CONFIG=${2:?"Missing config path"}
NSHARDS=${3:-200}
SHARD_ID=${SLURM_ARRAY_TASK_ID}

PROJECT_ROOT=${PROJECT_ROOT:-$PWD}
cd "${PROJECT_ROOT}"

mkdir -p logs

echo "[$(date)] Starting ${STAGE} shard ${SHARD_ID}/${NSHARDS} on ${HOSTNAME}"
echo "Config: ${CONFIG}"
echo "SLURM_JOB_ID=${SLURM_JOB_ID:-NA}"

# Load local environment. Edit to match IU Quartz setup.
# module load python
# module load conda
# conda activate marketscan-hpc

python "src/${STAGE}.py" \
  --config "${CONFIG}" \
  --shard-id "${SHARD_ID}" \
  --n-shards "${NSHARDS}"

echo "[$(date)] Completed ${STAGE} shard ${SHARD_ID}/${NSHARDS}"
