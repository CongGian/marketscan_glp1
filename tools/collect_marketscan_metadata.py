#!/usr/bin/env python3
"""
Create a PHI-safe metadata manifest for a local MarketScan extract.

The script reads file metadata, Parquet footers, and CSV headers only. It does
not print row-level values, claim lines, patient IDs, service dates, or costs.
Run it inside the approved restricted-data environment, then review the JSON
before sharing it.
"""

import argparse
import csv
import datetime as dt
import hashlib
import json
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any, Dict, List, Optional, Set

try:
    import pyarrow.parquet as pq
except Exception:  # pragma: no cover - depends on local HPC modules/env
    pq = None


KNOWN_EXTENSIONS = {
    ".parquet",
    ".csv",
    ".sas7bdat",
    ".xpt",
}

MODULE_LETTER_HINTS = {
    "a": "annual_enrollment_A",
    "d": "pharmacy_D",
    "t": "enrollment_T",
    "i": "inpatient_I",
    "o": "outpatient_O",
    "s": "services_S",
    "f": "facility_F",
}

CONCEPT_ALIASES = {
    "enrollee_id": ["ENROLID", "ENROLLEE_ID", "MEMBER_ID", "PATID", "ID"],
    "claim_id": ["CLAIM_ID", "CLMID", "MSCLMID", "SEQNUM", "CASEID"],
    "service_start": ["SVCDATE", "SERVICE_DATE", "FROMDATE", "FDATE", "ADMDATE"],
    "service_end": ["TSVCDAT", "SERVICE_END", "TODATE", "TDATE", "DISDATE"],
    "fill_date": ["SVCDATE", "FILL_DATE", "RXDATE", "SERVICE_DATE"],
    "enroll_start": ["DTSTART", "ENROLL_START", "ENR_START", "ELIG_START"],
    "enroll_end": ["DTEND", "ENROLL_END", "ENR_END", "ELIG_END"],
    "ndc": ["NDCNUM", "NDC", "NDC11", "NDC_CODE"],
    "days_supply": ["DAYSUPP", "DAYS_SUPPLY", "DAYSSUP", "DAYSUPPLY"],
    "quantity": ["QTY", "QUANTITY", "METQTY"],
    "rx_benefit": ["RX", "RXCOV", "RX_BENEFIT", "DRUGCOV"],
    "medical_benefit": ["MED", "MEDCOV", "MEDICAL_BENEFIT"],
    "age": ["AGE", "AGEYR", "AGE_YEAR"],
    "sex": ["SEX", "GENDER"],
    "region": ["REGION", "GEOGRAPHIC_REGION"],
    "plan_type": ["PLANTYP", "PLAN_TYPE", "HLTHPLAN"],
    "allowed_amount": ["PAY", "TOTPAY", "HOSPPAY", "PHYSPAY", "ALLOW", "ALLOWED", "ALLOWED_AMOUNT"],
    "plan_paid": ["NETPAY", "TOTNET", "HOSPNET", "PLAN_PAY", "PLANPAID", "PLAN_PAID"],
    "copay": ["COPAY", "COPAYMENT"],
    "coinsurance": ["COINS", "COINSURANCE"],
    "deductible": ["DED", "DEDUCT", "DEDUCTIBLE"],
    "patient_pay": ["PATPAY", "PATIENT_PAY", "OOP", "PATIENT_OOP"],
    "place_of_service": ["STDPLAC", "PLACE_OF_SERVICE", "POS"],
    "revenue_code": ["REVCD", "REVENUE_CODE"],
    "procedure": ["PROC", "PROCCD", "PROCEDURE", "CPT", "HCPCS"],
    "diagnosis": ["DX", "DIAG", "DX1", "PDX", "DXVER"],
}


REQUIRED_CONCEPTS = {
    "current_glp1_pool_prototype": {
        "pharmacy_D": ["enrollee_id", "fill_date", "ndc", "days_supply"],
        "enrollment_T": ["enrollee_id", "enroll_start", "enroll_end", "rx_benefit"],
    },
    "full_dpp4_to_glp1_person_month": {
        "pharmacy": [
            "enrollee_id",
            "fill_date",
            "ndc",
            "days_supply",
            "quantity",
            "allowed_amount",
            "plan_paid",
            "copay",
            "coinsurance",
            "deductible",
            "patient_pay",
        ],
        "enrollment": [
            "enrollee_id",
            "enroll_start",
            "enroll_end",
            "rx_benefit",
            "medical_benefit",
            "age",
            "sex",
            "region",
            "plan_type",
        ],
        "medical": [
            "enrollee_id",
            "service_start",
            "service_end",
            "claim_id",
            "place_of_service",
            "revenue_code",
            "diagnosis",
            "procedure",
            "allowed_amount",
            "plan_paid",
            "copay",
            "coinsurance",
            "deductible",
            "patient_pay",
        ],
    },
}


def parse_args():
    parser = argparse.ArgumentParser(
        description="Collect schema-only MarketScan metadata without row values.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--raw-root",
        type=Path,
        required=True,
        help="Root directory containing local MarketScan raw files.",
    )
    parser.add_argument(
        "--code-list-root",
        type=Path,
        default=None,
        help="Optional root containing NDC/diagnosis/procedure code-list files.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(
            "/PATH/TO/RESTRICTED_WORKSPACE/"
            "metadata/marketscan_metadata_manifest.json"
        ),
        help="JSON manifest path to write.",
    )
    parser.add_argument(
        "--years",
        nargs="+",
        default=["2017", "2018", "2019", "2020", "2021", "2022", "2023"],
        help="Years to scan. Comma-separated values are also accepted.",
    )
    parser.add_argument(
        "--module",
        action="append",
        default=[],
        metavar="NAME=GLOB",
        help=(
            "Explicit module glob relative to raw-root. The placeholder {year} "
            "is replaced for each requested year. Repeat for multiple modules."
        ),
    )
    parser.add_argument(
        "--auto-inventory",
        action="store_true",
        help="If no --module is supplied, recursively inventory supported files.",
    )
    parser.add_argument(
        "--schema-files-per-group",
        type=int,
        default=3,
        help="Number of files per module-year group whose schema footers are checked.",
    )
    parser.add_argument(
        "--include-row-counts",
        action="store_true",
        help="Include Parquet footer row counts. No row values are read.",
    )
    parser.add_argument(
        "--include-relative-file-examples",
        action="store_true",
        help="Include a few relative file paths. Keep off if paths are sensitive.",
    )
    parser.add_argument(
        "--max-relative-file-examples",
        type=int,
        default=3,
        help="Maximum file examples per module-year when examples are enabled.",
    )
    return parser.parse_args()


def normalize_years(raw_years):
    # type: (List[str]) -> List[str]
    years = []  # type: List[str]
    for item in raw_years:
        for part in item.split(","):
            part = part.strip()
            if part:
                years.append(part)
    return years


def parse_module_specs(specs):
    # type: (List[str]) -> Dict[str, str]
    modules = {}  # type: Dict[str, str]
    for spec in specs:
        if "=" not in spec:
            raise SystemExit(f"--module must be NAME=GLOB, got: {spec}")
        name, pattern = spec.split("=", 1)
        name = name.strip()
        pattern = pattern.strip()
        if not name or not pattern:
            raise SystemExit(f"--module must be NAME=GLOB, got: {spec}")
        modules[name] = pattern
    return modules


def file_extension(path):
    # type: (Path) -> str
    lower = path.name.lower()
    if lower.endswith(".snappy.parquet"):
        return ".parquet"
    return path.suffix.lower()


def infer_year(path, requested_years):
    # type: (Path, Set[str]) -> str
    for part in path.parts:
        if part in requested_years:
            return part
    match = re.search(r"(20\d{2})", path.as_posix())
    if match and match.group(1) in requested_years:
        return match.group(1)
    return "unknown"


def infer_module(path):
    # type: (Path) -> str
    name = path.name.lower()
    for letter, label in MODULE_LETTER_HINTS.items():
        if re.search(rf"(^|_){letter}(_|\\.)", name):
            return label
    stem = re.sub(r"[^a-z0-9]+", "_", path.stem.lower()).strip("_")
    return stem[:80] if stem else "unknown_module"


def discover_files(
    raw_root,
    years,
    modules,
    auto_inventory,
):
    # type: (Path, List[str], Dict[str, str], bool) -> Dict[str, Dict[str, List[Path]]]
    requested_years = set(years)
    groups = defaultdict(lambda: defaultdict(list))  # type: Dict[str, Dict[str, List[Path]]]

    if modules:
        for module_name, pattern in modules.items():
            for year in years:
                year_pattern = pattern.format(year=year)
                for path in sorted(raw_root.glob(year_pattern)):
                    if path.is_file():
                        groups[module_name][year].append(path)
        return groups

    if not auto_inventory:
        raise SystemExit("Provide at least one --module NAME=GLOB or pass --auto-inventory.")

    for path in raw_root.rglob("*"):
        if not path.is_file():
            continue
        if file_extension(path) not in KNOWN_EXTENSIONS:
            continue
        rel = path.relative_to(raw_root)
        year = infer_year(rel, requested_years)
        if year == "unknown":
            continue
        groups[infer_module(rel)][year].append(path)

    return groups


def parquet_schema(path, include_row_counts):
    # type: (Path, bool) -> Dict[str, Any]
    if pq is None:
        return {
            "path_hash": stable_hash(path.as_posix()),
            "schema_reader": "pyarrow_missing",
            "error": "pyarrow is not available in this Python environment",
        }

    try:
        parquet_file = pq.ParquetFile(path)
        schema = parquet_file.schema_arrow
        columns = []
        for field in schema:
            columns.append(
                {
                    "name": field.name,
                    "type": str(field.type),
                    "nullable": bool(field.nullable),
                }
            )
        result = {
            "schema_reader": "pyarrow.parquet_footer",
            "columns": columns,
        }  # type: Dict[str, Any]
        if include_row_counts:
            result["row_count_footer"] = parquet_file.metadata.num_rows
        return result
    except Exception as exc:
        return {
            "schema_reader": "pyarrow.parquet_footer",
            "error": f"{type(exc).__name__}: {exc}",
        }


def csv_header(path):
    # type: (Path) -> Dict[str, Any]
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            reader = csv.reader(handle)
            header = next(reader, [])
            rows = sum(1 for _ in reader)
        return {
            "schema_reader": "csv_header_only",
            "columns": [{"name": name, "type": "unknown_csv", "nullable": None} for name in header],
            "row_count_lines_minus_header": rows,
        }
    except UnicodeDecodeError:
        try:
            with path.open("r", encoding="latin-1", newline="") as handle:
                reader = csv.reader(handle)
                header = next(reader, [])
                rows = sum(1 for _ in reader)
            return {
                "schema_reader": "csv_header_only_latin1",
                "columns": [{"name": name, "type": "unknown_csv", "nullable": None} for name in header],
                "row_count_lines_minus_header": rows,
            }
        except Exception as exc:
            return {"schema_reader": "csv_header_only", "error": f"{type(exc).__name__}: {exc}"}
    except Exception as exc:
        return {"schema_reader": "csv_header_only", "error": f"{type(exc).__name__}: {exc}"}


def unsupported_schema(path):
    # type: (Path) -> Dict[str, Any]
    return {
        "schema_reader": "unsupported_footer_only",
        "extension": file_extension(path),
        "note": "File counted but schema not read by this script.",
    }


def stable_hash(value):
    # type: (str) -> str
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]


def schema_signature(schema):
    # type: (Dict[str, Any]) -> str
    columns = schema.get("columns")
    if not columns:
        return stable_hash(json.dumps(schema, sort_keys=True))
    simple = [(col.get("name"), col.get("type"), col.get("nullable")) for col in columns]
    return stable_hash(json.dumps(simple, sort_keys=True))


def read_schema(path, include_row_counts):
    # type: (Path, bool) -> Dict[str, Any]
    ext = file_extension(path)
    if ext == ".parquet":
        return parquet_schema(path, include_row_counts)
    if ext == ".csv":
        return csv_header(path)
    return unsupported_schema(path)


def summarize_group(
    raw_root,
    files,
    schema_files_per_group,
    include_row_counts,
    include_relative_file_examples,
    max_relative_file_examples,
):
    # type: (Path, List[Path], int, bool, bool, int) -> Dict[str, Any]
    files = sorted(files)
    total_bytes = sum(path.stat().st_size for path in files)
    extensions = sorted({file_extension(path) for path in files})
    schema_samples = [
        read_schema(path, include_row_counts)
        for path in files[: max(0, schema_files_per_group)]
    ]
    signatures = [schema_signature(schema) for schema in schema_samples]
    unique_signatures = sorted(set(signatures))
    representative_schema = schema_samples[0] if schema_samples else {}

    summary = {
        "file_count": len(files),
        "total_bytes": total_bytes,
        "extensions": extensions,
        "schema_files_checked": len(schema_samples),
        "schema_variant_count_in_checked_files": len(unique_signatures),
        "schema_consistent_in_checked_files": len(unique_signatures) <= 1,
        "representative_schema": representative_schema,
    }  # type: Dict[str, Any]

    if include_relative_file_examples:
        summary["relative_file_examples"] = [
            path.relative_to(raw_root).as_posix()
            for path in files[: max_relative_file_examples]
        ]

    if include_row_counts:
        row_counts = [
            schema.get("row_count_footer")
            for schema in schema_samples
            if isinstance(schema.get("row_count_footer"), int)
        ]
        summary["row_count_footer_sum_checked_files"] = sum(row_counts) if row_counts else None

    return summary


def column_names_from_summary(summary):
    # type: (Dict[str, Any]) -> List[str]
    schema = summary.get("representative_schema", {})
    columns = schema.get("columns", [])
    return [str(col.get("name", "")) for col in columns if col.get("name")]


def suggest_mappings(columns):
    # type: (List[str]) -> Dict[str, List[str]]
    upper_to_originals = defaultdict(list)  # type: Dict[str, List[str]]
    for col in columns:
        upper_to_originals[col.upper()].append(col)

    suggestions = {}  # type: Dict[str, List[str]]
    for concept, aliases in CONCEPT_ALIASES.items():
        hits = []  # type: List[str]
        for alias in aliases:
            hits.extend(upper_to_originals.get(alias.upper(), []))
        if concept == "diagnosis":
            hits.extend([col for col in columns if re.match(r"(?i)^(dx|diag)", col)])
        if concept == "procedure":
            hits.extend([col for col in columns if re.match(r"(?i)^(proc|cpt|hcpcs)", col)])
        if hits:
            suggestions[concept] = sorted(set(hits), key=str.upper)
    return suggestions


def summarize_code_lists(code_list_root):
    # type: (Optional[Path]) -> Dict[str, Any]
    if code_list_root is None:
        return {"provided": False}
    if not code_list_root.exists():
        return {"provided": True, "exists": False, "path_redacted": True}

    files = []  # type: List[Dict[str, Any]]
    for path in sorted(code_list_root.rglob("*")):
        if not path.is_file():
            continue
        if file_extension(path) not in {".csv", ".parquet"}:
            continue
        schema = read_schema(path, include_row_counts=True)
        files.append(
            {
                "relative_path": path.relative_to(code_list_root).as_posix(),
                "extension": file_extension(path),
                "schema": schema,
            }
        )
    return {
        "provided": True,
        "exists": True,
        "path_redacted": True,
        "file_count": len(files),
        "files": files,
    }


def build_manifest(args):
    # type: (argparse.Namespace) -> Dict[str, Any]
    years = normalize_years(args.years)
    modules = parse_module_specs(args.module)
    raw_root = args.raw_root.resolve()
    if not raw_root.exists():
        raise SystemExit(f"raw-root does not exist: {raw_root}")

    groups = discover_files(raw_root, years, modules, args.auto_inventory)

    module_output = {}  # type: Dict[str, Any]
    for module_name in sorted(groups):
        module_years = {}  # type: Dict[str, Any]
        all_columns = set()  # type: Set[str]
        for year in years:
            files = groups[module_name].get(year, [])
            summary = summarize_group(
                raw_root=raw_root,
                files=files,
                schema_files_per_group=args.schema_files_per_group,
                include_row_counts=args.include_row_counts,
                include_relative_file_examples=args.include_relative_file_examples,
                max_relative_file_examples=args.max_relative_file_examples,
            )
            module_years[year] = summary
            all_columns.update(column_names_from_summary(summary))

        module_output[module_name] = {
            "years": module_years,
            "all_representative_columns": sorted(all_columns, key=str.upper),
            "suggested_concept_mappings": suggest_mappings(sorted(all_columns, key=str.upper)),
        }
        if module_name in modules:
            module_output[module_name]["configured_pattern"] = modules[module_name]

    return {
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "script": Path(__file__).name,
        "privacy_boundary": {
            "row_level_values_exported": False,
            "patient_identifiers_exported": False,
            "exact_service_dates_exported": False,
            "cost_values_exported": False,
            "raw_root_redacted": True,
            "notes": [
                "Review this file before sharing.",
                "Column names, file counts, schemas, and code-list headers are intended metadata.",
                "Do not enable relative file examples if local paths are restricted.",
                "Parquet schemas are read from footers; no row groups are converted to records.",
            ],
        },
        "scan_options": {
            "years": years,
            "explicit_modules": bool(modules),
            "auto_inventory": bool(args.auto_inventory),
            "schema_files_per_group": args.schema_files_per_group,
            "include_row_counts": bool(args.include_row_counts),
            "include_relative_file_examples": bool(args.include_relative_file_examples),
        },
        "module_metadata": module_output,
        "code_list_metadata": summarize_code_lists(args.code_list_root.resolve() if args.code_list_root else None),
        "required_metadata_checklist": REQUIRED_CONCEPTS,
        "manual_items_still_needed": [
            "Confirm which module/table corresponds to pharmacy claims, enrollment, inpatient, outpatient, and facility claims.",
            "Confirm date storage types and origins, especially whether integer dates are SAS days since 1960-01-01.",
            "Confirm active pharmacy and medical benefit flag values.",
            "Confirm NDC formatting rules and whether leading zeros are preserved.",
            "Confirm cost units and sign conventions for allowed, plan-paid, copay, coinsurance, deductible, and patient-pay fields.",
            "Confirm diagnosis/procedure code systems, decimal handling, and prefix/exact match rules.",
            "Provide external code-list file names and headers for GLP-1, DPP-4, other diabetes medications, diagnosis groups, and procedures.",
            "Confirm Slurm account, partition, CPU, memory, time, and shard count.",
        ],
    }


def main() -> int:
    args = parse_args()
    manifest = build_manifest(args)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote metadata manifest: {args.output}")
    print("Review the JSON before sharing it. It should contain metadata only, not row-level data.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
