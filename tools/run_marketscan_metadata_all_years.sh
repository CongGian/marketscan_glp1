#!/usr/bin/env bash
set -euo pipefail

# Build a metadata-only manifest for the local MarketScan parquet delivery.
#
# This wrapper reads file metadata, Parquet footers, and code-list headers only
# through tools/collect_marketscan_metadata.py. It does not export row-level
# claims, enrollee IDs, service dates, NDC values from claims, diagnosis values
# from claims, or cost values.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

RAW_ROOT="${RAW_ROOT:-/PATH/TO/RESTRICTED_MARKETSCAN_PARQUET}"
RESTRICTED_ROOT="${RESTRICTED_ROOT:-/PATH/TO/RESTRICTED_WORKSPACE}"
OUTPUT="${OUTPUT:-${RESTRICTED_ROOT}/metadata/marketscan_metadata_manifest_all_years.json}"
CODE_LIST_ROOT="${CODE_LIST_ROOT:-${PROJECT_ROOT}/code_lists}"

# Default to every year in the filename list the analyst provided.
# Override with, for example:
#   YEARS="2017 2018 2019 2020 2021 2022 2023" tools/run_marketscan_metadata_all_years.sh
YEARS="${YEARS:-2016 2017 2018 2019 2020 2021 2022 2023 2024}"

EXTRA_ARGS=()
if [[ "${INCLUDE_ROW_COUNTS:-0}" == "1" ]]; then
  # Parquet footer counts are aggregate metadata, not row values. Keep this off
  # unless your DUA/project norms allow sharing those counts.
  EXTRA_ARGS+=(--include-row-counts)
fi

if [[ "${INCLUDE_FILE_EXAMPLES:-0}" == "1" ]]; then
  # Relative file examples are usually harmless here because filenames are
  # generic, but keep this off unless you want them in the manifest.
  EXTRA_ARGS+=(--include-relative-file-examples)
fi

if [[ ! -d "${RAW_ROOT}" ]]; then
  echo "ERROR: RAW_ROOT does not exist or is not a directory: ${RAW_ROOT}" >&2
  echo "Set RAW_ROOT=/path/to/parquet and rerun." >&2
  exit 1
fi

mkdir -p "$(dirname "${OUTPUT}")"

cd "${PROJECT_ROOT}"

echo "Building MarketScan metadata manifest"
echo "  raw root:       ${RAW_ROOT}"
echo "  output:         ${OUTPUT}"
echo "  code-list root: ${CODE_LIST_ROOT}"
echo "  years:          ${YEARS}"
echo

python3 tools/collect_marketscan_metadata.py \
  --raw-root "${RAW_ROOT}" \
  --code-list-root "${CODE_LIST_ROOT}" \
  --years ${YEARS} \
  --module annual_enrollment_A='mscan_{year}_a.parquet' \
  --module pharmacy_D='mscan_{year}_d.parquet' \
  --module facility_header_F='mscan_{year}_f.parquet' \
  --module inpatient_I='mscan_{year}_i.parquet' \
  --module outpatient_O='mscan_{year}_o.parquet' \
  --module inpatient_services_S='mscan_{year}_s.parquet' \
  --module enrollment_detail_T='mscan_{year}_t.parquet' \
  --output "${OUTPUT}" \
  "${EXTRA_ARGS[@]}"

echo
echo "Done. Review before sharing:"
echo "  ${OUTPUT}"
