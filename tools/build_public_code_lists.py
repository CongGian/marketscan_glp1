#!/usr/bin/env python3
"""
Build public, source-backed clinical concept files for the MarketScan pipeline.

Drug NDC lists are generated from the NIH/NLM RxNorm API using historical NDC
associations. Diagnosis lists are seed ICD-10-CM prefix/exact lists based on
public claims-algorithm sources and should be reviewed before final analysis.
"""

import argparse
import csv
import datetime as dt
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path


RXNORM_BASE = "https://rxnav.nlm.nih.gov/REST"
RXNORM_SOURCE = "NIH/NLM RxNorm API getAllHistoricalNDCs"
RXNORM_SOURCE_URL = "https://lhncbc.nlm.nih.gov/RxNav/APIs/api-RxNorm.getAllHistoricalNDCs.html"

FDA_NDC_SOURCE = "FDA National Drug Code Directory"
FDA_NDC_SOURCE_URL = "https://www.fda.gov/drugs/drug-approvals-and-databases/national-drug-code-directory"

AHRQ_ELIX_SOURCE = "AHRQ HCUP Elixhauser Comorbidity Software Refined for ICD-10-CM"
AHRQ_ELIX_URL = "https://hcup-us.ahrq.gov/toolssoftware/comorbidityicd10/comorbidity_icd10.jsp"

CCW_SOURCE = "CMS Chronic Conditions Data Warehouse algorithms"
CCW_URL = "https://www2.ccwdata.org/web/guest/condition-categories"

CDC_ICD_SOURCE = "CDC/NCHS ICD-10-CM diagnosis coding system"
CDC_ICD_URL = "https://www.cdc.gov/nchs/icd/icd-10-cm/index.html"


DRUG_CLASS_DEFINITIONS = {
    "glp1_ndc": {
        "label": "GLP-1 receptor agonist",
        "notes": "Primary GLP-1 RA class; excludes tirzepatide unless using glp1_like_ndc.",
        "ingredients": [
            "albiglutide",
            "exenatide",
            "liraglutide",
            "lixisenatide",
            "dulaglutide",
            "semaglutide",
        ],
    },
    "tirzepatide_ndc": {
        "label": "Dual GIP/GLP-1 receptor agonist",
        "notes": "Keep separate so inclusion can be controlled by config.",
        "ingredients": ["tirzepatide"],
    },
    "dpp4_ndc": {
        "label": "DPP-4 inhibitor",
        "notes": "Includes fixed-dose combination products when RxNorm links them to the ingredient.",
        "ingredients": ["sitagliptin", "saxagliptin", "linagliptin", "alogliptin"],
    },
    "metformin_ndc": {
        "label": "Metformin",
        "notes": "Includes metformin-containing fixed-dose combination products.",
        "ingredients": ["metformin"],
    },
    "insulin_ndc": {
        "label": "Insulin",
        "notes": "Broad insulin class, including analogs and human insulin products.",
        "ingredients": [
            "insulin human",
            "insulin aspart",
            "insulin degludec",
            "insulin detemir",
            "insulin glargine",
            "insulin glulisine",
            "insulin isophane",
            "insulin lispro",
            "regular insulin, human",
        ],
    },
    "sglt2_ndc": {
        "label": "SGLT2 inhibitor",
        "notes": "Includes fixed-dose combination products when RxNorm links them to the ingredient.",
        "ingredients": [
            "canagliflozin",
            "dapagliflozin",
            "empagliflozin",
            "ertugliflozin",
            "bexagliflozin",
            "sotagliflozin",
        ],
    },
    "sulfonylurea_ndc": {
        "label": "Sulfonylurea",
        "notes": "Broad sulfonylurea class.",
        "ingredients": [
            "acetohexamide",
            "chlorpropamide",
            "glimepiride",
            "glipizide",
            "glyburide",
            "tolazamide",
            "tolbutamide",
        ],
    },
    "tzd_ndc": {
        "label": "Thiazolidinedione",
        "notes": "TZD class.",
        "ingredients": ["pioglitazone", "rosiglitazone"],
    },
    "other_diabetes_ndc": {
        "label": "Other diabetes medication",
        "notes": "Exploratory non-primary diabetes medication classes.",
        "ingredients": [
            "acarbose",
            "miglitol",
            "nateglinide",
            "repaglinide",
            "pramlintide",
            "bromocriptine",
            "colesevelam",
        ],
    },
}


DIAGNOSIS_GROUPS = {
    "type2_diabetes": {
        "label": "Type 2 diabetes mellitus",
        "rule": "Often used as at least 1 inpatient or 2 outpatient claims in baseline; study-specific.",
        "source": CCW_SOURCE,
        "source_url": CCW_URL,
        "rows": [
            ("prefix", "E11", "Type 2 diabetes mellitus"),
        ],
    },
    "diabetes_any": {
        "label": "Diabetes mellitus, any specified type",
        "rule": "Use for broad diabetes history; use type2_diabetes for T2D-specific restriction.",
        "source": CCW_SOURCE,
        "source_url": CCW_URL,
        "rows": [
            ("prefix", "E08", "Diabetes mellitus due to underlying condition"),
            ("prefix", "E09", "Drug or chemical induced diabetes mellitus"),
            ("prefix", "E10", "Type 1 diabetes mellitus"),
            ("prefix", "E11", "Type 2 diabetes mellitus"),
            ("prefix", "E13", "Other specified diabetes mellitus"),
        ],
    },
    "obesity": {
        "label": "Overweight, obesity, and adult BMI codes",
        "rule": "Usually any diagnosis claim in baseline; BMI Z codes are supplemental.",
        "source": AHRQ_ELIX_SOURCE,
        "source_url": AHRQ_ELIX_URL,
        "rows": [
            ("prefix", "E66", "Overweight and obesity"),
            ("prefix", "Z683", "Adult BMI 30.0-39.9 range"),
            ("prefix", "Z684", "Adult BMI 40.0 and over range"),
        ],
    },
    "chronic_kidney_disease": {
        "label": "Chronic kidney disease and kidney-failure related history",
        "rule": "Baseline comorbidity; consider stage-specific flags from N18 subcodes.",
        "source": CCW_SOURCE,
        "source_url": CCW_URL,
        "rows": [
            ("prefix", "N18", "Chronic kidney disease"),
            ("prefix", "N19", "Unspecified kidney failure"),
            ("prefix", "I12", "Hypertensive chronic kidney disease"),
            ("prefix", "I13", "Hypertensive heart and chronic kidney disease"),
            ("exact", "Z940", "Kidney transplant status"),
            ("exact", "Z992", "Dependence on renal dialysis"),
        ],
    },
    "cardiovascular_or_ascvd": {
        "label": "Cardiovascular disease / ASCVD proxy",
        "rule": "Broad CVD history; refine for specific endpoints.",
        "source": CCW_SOURCE,
        "source_url": CCW_URL,
        "rows": [
            ("prefix", "I20", "Angina pectoris"),
            ("prefix", "I21", "Acute myocardial infarction"),
            ("prefix", "I22", "Subsequent myocardial infarction"),
            ("prefix", "I23", "Complications following acute myocardial infarction"),
            ("prefix", "I24", "Other acute ischemic heart diseases"),
            ("prefix", "I25", "Chronic ischemic heart disease"),
            ("prefix", "I60", "Nontraumatic subarachnoid hemorrhage"),
            ("prefix", "I61", "Nontraumatic intracerebral hemorrhage"),
            ("prefix", "I62", "Other nontraumatic intracranial hemorrhage"),
            ("prefix", "I63", "Cerebral infarction"),
            ("prefix", "I64", "Stroke, not specified as hemorrhage or infarction"),
            ("prefix", "I65", "Occlusion and stenosis of precerebral arteries"),
            ("prefix", "I66", "Occlusion and stenosis of cerebral arteries"),
            ("prefix", "I67", "Other cerebrovascular diseases"),
            ("prefix", "I68", "Cerebrovascular disorders in diseases classified elsewhere"),
            ("prefix", "I69", "Sequelae of cerebrovascular disease"),
            ("prefix", "I70", "Atherosclerosis"),
            ("prefix", "I73", "Other peripheral vascular diseases"),
            ("prefix", "I74", "Arterial embolism and thrombosis"),
        ],
    },
    "heart_failure": {
        "label": "Heart failure",
        "rule": "Baseline comorbidity or monthly outcome; pair with IP/OP claim rule.",
        "source": AHRQ_ELIX_SOURCE,
        "source_url": AHRQ_ELIX_URL,
        "rows": [
            ("prefix", "I50", "Heart failure"),
            ("exact", "I110", "Hypertensive heart disease with heart failure"),
            ("exact", "I130", "Hypertensive heart and CKD with heart failure and stage 1-4/unspecified CKD"),
            ("exact", "I132", "Hypertensive heart and CKD with heart failure and stage 5/end stage CKD"),
        ],
    },
    "hypertension": {
        "label": "Hypertension",
        "rule": "CCW-style rule commonly uses 1 inpatient/SNF/HHA or 2 outpatient/carrier claims.",
        "source": CCW_SOURCE,
        "source_url": CCW_URL,
        "rows": [
            ("exact", "I10", "Essential hypertension"),
            ("prefix", "I11", "Hypertensive heart disease"),
            ("prefix", "I12", "Hypertensive chronic kidney disease"),
            ("prefix", "I13", "Hypertensive heart and chronic kidney disease"),
            ("prefix", "I15", "Secondary hypertension"),
            ("prefix", "H3503", "Hypertensive retinopathy"),
            ("exact", "I674", "Hypertensive encephalopathy"),
            ("exact", "N262", "Page kidney"),
        ],
    },
    "dyslipidemia": {
        "label": "Dyslipidemia / hyperlipidemia",
        "rule": "Baseline comorbidity.",
        "source": CCW_SOURCE,
        "source_url": CCW_URL,
        "rows": [
            ("prefix", "E78", "Disorders of lipoprotein metabolism and other lipidemias"),
        ],
    },
    "sleep_apnea": {
        "label": "Sleep apnea",
        "rule": "Baseline comorbidity.",
        "source": CDC_ICD_SOURCE,
        "source_url": CDC_ICD_URL,
        "rows": [
            ("prefix", "G473", "Sleep apnea"),
        ],
    },
    "liver_disease": {
        "label": "Liver disease",
        "rule": "Baseline comorbidity; refine alcohol/non-alcohol etiologies if needed.",
        "source": AHRQ_ELIX_SOURCE,
        "source_url": AHRQ_ELIX_URL,
        "rows": [
            ("prefix", "B18", "Chronic viral hepatitis"),
            ("prefix", "K70", "Alcoholic liver disease"),
            ("prefix", "K71", "Toxic liver disease"),
            ("prefix", "K72", "Hepatic failure"),
            ("prefix", "K73", "Chronic hepatitis"),
            ("prefix", "K74", "Fibrosis and cirrhosis of liver"),
            ("prefix", "K75", "Other inflammatory liver diseases"),
            ("prefix", "K76", "Other diseases of liver"),
            ("prefix", "K77", "Liver disorders in diseases classified elsewhere"),
            ("exact", "Z944", "Liver transplant status"),
        ],
    },
    "depression_anxiety": {
        "label": "Depression and anxiety",
        "rule": "Baseline mental-health comorbidity; consider separating depression and anxiety.",
        "source": AHRQ_ELIX_SOURCE,
        "source_url": AHRQ_ELIX_URL,
        "rows": [
            ("prefix", "F32", "Major depressive disorder, single episode"),
            ("prefix", "F33", "Major depressive disorder, recurrent"),
            ("exact", "F341", "Dysthymic disorder"),
            ("prefix", "F40", "Phobic anxiety disorders"),
            ("prefix", "F41", "Other anxiety disorders"),
            ("prefix", "F431", "Post-traumatic stress disorder"),
        ],
    },
    "substance_use": {
        "label": "Substance use disorders",
        "rule": "Baseline comorbidity or sensitivity exclusion.",
        "source": AHRQ_ELIX_SOURCE,
        "source_url": AHRQ_ELIX_URL,
        "rows": [
            ("prefix", "F10", "Alcohol related disorders"),
            ("prefix", "F11", "Opioid related disorders"),
            ("prefix", "F12", "Cannabis related disorders"),
            ("prefix", "F13", "Sedative, hypnotic, or anxiolytic related disorders"),
            ("prefix", "F14", "Cocaine related disorders"),
            ("prefix", "F15", "Other stimulant related disorders"),
            ("prefix", "F16", "Hallucinogen related disorders"),
            ("prefix", "F18", "Inhalant related disorders"),
            ("prefix", "F19", "Other psychoactive substance related disorders"),
        ],
    },
    "diabetic_complications": {
        "label": "Diabetes with complications",
        "rule": "Use as a diabetes severity feature; excludes uncomplicated diabetes codes.",
        "source": AHRQ_ELIX_SOURCE,
        "source_url": AHRQ_ELIX_URL,
        "rows": [
            ("prefix", "E082", "Diabetes due to underlying condition with kidney complications"),
            ("prefix", "E083", "Diabetes due to underlying condition with ophthalmic complications"),
            ("prefix", "E084", "Diabetes due to underlying condition with neurological complications"),
            ("prefix", "E085", "Diabetes due to underlying condition with circulatory complications"),
            ("prefix", "E086", "Diabetes due to underlying condition with other specified complications"),
            ("prefix", "E092", "Drug or chemical induced diabetes with kidney complications"),
            ("prefix", "E093", "Drug or chemical induced diabetes with ophthalmic complications"),
            ("prefix", "E094", "Drug or chemical induced diabetes with neurological complications"),
            ("prefix", "E095", "Drug or chemical induced diabetes with circulatory complications"),
            ("prefix", "E096", "Drug or chemical induced diabetes with other specified complications"),
            ("prefix", "E102", "Type 1 diabetes with kidney complications"),
            ("prefix", "E103", "Type 1 diabetes with ophthalmic complications"),
            ("prefix", "E104", "Type 1 diabetes with neurological complications"),
            ("prefix", "E105", "Type 1 diabetes with circulatory complications"),
            ("prefix", "E106", "Type 1 diabetes with other specified complications"),
            ("prefix", "E112", "Type 2 diabetes with kidney complications"),
            ("prefix", "E113", "Type 2 diabetes with ophthalmic complications"),
            ("prefix", "E114", "Type 2 diabetes with neurological complications"),
            ("prefix", "E115", "Type 2 diabetes with circulatory complications"),
            ("prefix", "E116", "Type 2 diabetes with other specified complications"),
            ("prefix", "E132", "Other specified diabetes with kidney complications"),
            ("prefix", "E133", "Other specified diabetes with ophthalmic complications"),
            ("prefix", "E134", "Other specified diabetes with neurological complications"),
            ("prefix", "E135", "Other specified diabetes with circulatory complications"),
            ("prefix", "E136", "Other specified diabetes with other specified complications"),
        ],
    },
    "gi_adverse_event_proxy": {
        "label": "GI adverse-event proxy",
        "rule": "Exploratory monthly outcome proxy; should be clinically reviewed.",
        "source": CDC_ICD_SOURCE,
        "source_url": CDC_ICD_URL,
        "rows": [
            ("prefix", "K20", "Esophagitis"),
            ("prefix", "K21", "Gastro-esophageal reflux disease"),
            ("prefix", "K25", "Gastric ulcer"),
            ("prefix", "K26", "Duodenal ulcer"),
            ("prefix", "K27", "Peptic ulcer, site unspecified"),
            ("prefix", "K29", "Gastritis and duodenitis"),
            ("exact", "K30", "Functional dyspepsia"),
            ("prefix", "K31", "Other diseases of stomach and duodenum"),
            ("prefix", "K52", "Other and unspecified noninfective gastroenteritis and colitis"),
            ("prefix", "K59", "Other functional intestinal disorders"),
            ("prefix", "R10", "Abdominal and pelvic pain"),
            ("prefix", "R11", "Nausea and vomiting"),
        ],
    },
    "pancreatitis": {
        "label": "Pancreatitis",
        "rule": "Monthly safety outcome proxy.",
        "source": CDC_ICD_SOURCE,
        "source_url": CDC_ICD_URL,
        "rows": [
            ("prefix", "K85", "Acute pancreatitis"),
            ("exact", "K860", "Alcohol-induced chronic pancreatitis"),
            ("exact", "K861", "Other chronic pancreatitis"),
        ],
    },
    "gallbladder_disease": {
        "label": "Gallbladder and biliary disease",
        "rule": "Monthly safety outcome proxy.",
        "source": CDC_ICD_SOURCE,
        "source_url": CDC_ICD_URL,
        "rows": [
            ("prefix", "K80", "Cholelithiasis"),
            ("prefix", "K81", "Cholecystitis"),
            ("prefix", "K82", "Other diseases of gallbladder"),
            ("prefix", "K83", "Other diseases of biliary tract"),
        ],
    },
    "hypoglycemia": {
        "label": "Hypoglycemia",
        "rule": "Monthly outcome proxy.",
        "source": CDC_ICD_SOURCE,
        "source_url": CDC_ICD_URL,
        "rows": [
            ("exact", "E160", "Drug-induced hypoglycemia without coma"),
            ("exact", "E161", "Other hypoglycemia"),
            ("exact", "E162", "Hypoglycemia, unspecified"),
            ("prefix", "E0864", "Diabetes due to underlying condition with hypoglycemia"),
            ("prefix", "E0964", "Drug or chemical induced diabetes with hypoglycemia"),
            ("prefix", "E1064", "Type 1 diabetes with hypoglycemia"),
            ("prefix", "E1164", "Type 2 diabetes with hypoglycemia"),
            ("prefix", "E1364", "Other specified diabetes with hypoglycemia"),
        ],
    },
    "hyperglycemia": {
        "label": "Hyperglycemia",
        "rule": "Monthly outcome proxy.",
        "source": CDC_ICD_SOURCE,
        "source_url": CDC_ICD_URL,
        "rows": [
            ("exact", "R739", "Hyperglycemia, unspecified"),
            ("exact", "E0865", "Diabetes due to underlying condition with hyperglycemia"),
            ("exact", "E0965", "Drug or chemical induced diabetes with hyperglycemia"),
            ("exact", "E1065", "Type 1 diabetes with hyperglycemia"),
            ("exact", "E1165", "Type 2 diabetes with hyperglycemia"),
            ("exact", "E1365", "Other specified diabetes with hyperglycemia"),
        ],
    },
    "dka": {
        "label": "Diabetic ketoacidosis",
        "rule": "Monthly outcome proxy.",
        "source": CDC_ICD_SOURCE,
        "source_url": CDC_ICD_URL,
        "rows": [
            ("prefix", "E081", "Diabetes due to underlying condition with ketoacidosis"),
            ("prefix", "E091", "Drug or chemical induced diabetes with ketoacidosis"),
            ("prefix", "E101", "Type 1 diabetes with ketoacidosis"),
            ("prefix", "E111", "Type 2 diabetes with ketoacidosis"),
            ("prefix", "E131", "Other specified diabetes with ketoacidosis"),
        ],
    },
    "acute_kidney_event": {
        "label": "Acute kidney event",
        "rule": "Monthly outcome proxy; refine for inpatient-only sensitivity.",
        "source": CDC_ICD_SOURCE,
        "source_url": CDC_ICD_URL,
        "rows": [
            ("prefix", "N17", "Acute kidney failure"),
        ],
    },
    "acute_cvd_event": {
        "label": "Acute cardiovascular event",
        "rule": "Monthly outcome proxy; consider event-specific files for MI/stroke.",
        "source": CCW_SOURCE,
        "source_url": CCW_URL,
        "rows": [
            ("prefix", "I21", "Acute myocardial infarction"),
            ("prefix", "I22", "Subsequent myocardial infarction"),
            ("prefix", "I60", "Nontraumatic subarachnoid hemorrhage"),
            ("prefix", "I61", "Nontraumatic intracerebral hemorrhage"),
            ("prefix", "I62", "Other nontraumatic intracranial hemorrhage"),
            ("prefix", "I63", "Cerebral infarction"),
            ("exact", "I64", "Stroke, not specified as hemorrhage or infarction"),
            ("prefix", "G45", "Transient cerebral ischemic attacks and related syndromes"),
        ],
    },
}


def parse_args():
    parser = argparse.ArgumentParser(
        description="Generate public clinical concept CSVs.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--output-root", default="code_lists", type=Path)
    parser.add_argument("--skip-drugs", action="store_true", help="Only build diagnosis files.")
    parser.add_argument("--sleep", type=float, default=0.05, help="Pause between RxNorm API calls.")
    parser.add_argument("--retries", type=int, default=3)
    return parser.parse_args()


def read_json(url, retries, sleep_seconds):
    last_error = None
    for attempt in range(retries):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "marketscan-glp1-code-list-builder/0.1"})
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as exc:
            last_error = exc
            time.sleep(sleep_seconds * (attempt + 1) + 0.5)
    raise RuntimeError("Failed to read {}: {}".format(url, last_error))


def find_ingredient_rxcuis(ingredient, retries, sleep_seconds):
    params = urllib.parse.urlencode({"name": ingredient, "search": "2"})
    url = "{}/rxcui.json?{}".format(RXNORM_BASE, params)
    data = read_json(url, retries, sleep_seconds)
    return data.get("idGroup", {}).get("rxnormId", []) or []


def all_related_products(rxcui, retries, sleep_seconds):
    url = "{}/rxcui/{}/allrelated.json".format(RXNORM_BASE, rxcui)
    data = read_json(url, retries, sleep_seconds)
    groups = data.get("allRelatedGroup", {}).get("conceptGroup", []) or []
    products = []
    for group in groups:
        tty = group.get("tty")
        if tty not in {"SCD", "SBD", "GPCK", "BPCK"}:
            continue
        for concept in group.get("conceptProperties", []) or []:
            products.append(
                {
                    "rxcui": concept.get("rxcui", ""),
                    "name": concept.get("name", ""),
                    "tty": tty,
                }
            )
    return products


def historical_ndcs(product_rxcui, retries, sleep_seconds):
    url = "{}/rxcui/{}/allhistoricalndcs.json?history=2".format(RXNORM_BASE, product_rxcui)
    data = read_json(url, retries, sleep_seconds)
    concept = data.get("historicalNdcConcept", {}) or {}
    times = concept.get("historicalNdcTime", []) or []
    if isinstance(times, dict):
        times = [times]

    rows = []
    for hist in times:
        status = hist.get("status", "")
        direct_rxcui = hist.get("rxcui", "")
        ndc_times = hist.get("ndcTime", []) or []
        if isinstance(ndc_times, dict):
            ndc_times = [ndc_times]
        for ndc_time in ndc_times:
            ndc_value = ndc_time.get("ndc", "")
            if isinstance(ndc_value, list):
                ndc_value = ndc_value[0] if ndc_value else ""
            ndc_digits = normalize_digits(ndc_value)
            if len(ndc_digits) != 11:
                continue
            rows.append(
                {
                    "NDC11": ndc_digits,
                    "rxnorm_status": status,
                    "rxnorm_direct_rxcui": direct_rxcui,
                    "rxnorm_start_yyyymm": ndc_time.get("startDate", ""),
                    "rxnorm_end_yyyymm": ndc_time.get("endDate", ""),
                }
            )
    return rows


def normalize_digits(value):
    return "".join(ch for ch in str(value) if ch.isdigit())


def collapse_values(values):
    clean = sorted(set(str(value) for value in values if value not in ("", None)))
    return ";".join(clean)


def build_drug_rows(class_id, definition, retries, sleep_seconds):
    aggregated = {}
    detail_rows = []
    for ingredient in definition["ingredients"]:
        ingredient_rxcuis = find_ingredient_rxcuis(ingredient, retries, sleep_seconds)
        time.sleep(sleep_seconds)
        if not ingredient_rxcuis:
            detail_rows.append(
                {
                    "NDC11": "",
                    "drug_class": class_id,
                    "drug_class_label": definition["label"],
                    "ingredient": ingredient,
                    "rxnorm_ingredient_rxcui": "",
                    "rxnorm_product_rxcui": "",
                    "rxnorm_product_tty": "",
                    "rxnorm_product_name": "",
                    "rxnorm_status": "",
                    "rxnorm_direct_rxcui": "",
                    "rxnorm_start_yyyymm": "",
                    "rxnorm_end_yyyymm": "",
                    "source": RXNORM_SOURCE,
                    "source_url": RXNORM_SOURCE_URL,
                    "notes": "No RxCUI found for ingredient.",
                }
            )
            continue

        for ingredient_rxcui in ingredient_rxcuis:
            products = all_related_products(ingredient_rxcui, retries, sleep_seconds)
            time.sleep(sleep_seconds)
            for product in products:
                ndc_rows = historical_ndcs(product["rxcui"], retries, sleep_seconds)
                time.sleep(sleep_seconds)
                for ndc_row in ndc_rows:
                    row = {
                        "NDC11": ndc_row["NDC11"],
                        "drug_class": class_id,
                        "drug_class_label": definition["label"],
                        "ingredient": ingredient,
                        "rxnorm_ingredient_rxcui": ingredient_rxcui,
                        "rxnorm_product_rxcui": product["rxcui"],
                        "rxnorm_product_tty": product["tty"],
                        "rxnorm_product_name": product["name"],
                        "rxnorm_status": ndc_row["rxnorm_status"],
                        "rxnorm_direct_rxcui": ndc_row["rxnorm_direct_rxcui"],
                        "rxnorm_start_yyyymm": ndc_row["rxnorm_start_yyyymm"],
                        "rxnorm_end_yyyymm": ndc_row["rxnorm_end_yyyymm"],
                        "source": RXNORM_SOURCE,
                        "source_url": RXNORM_SOURCE_URL,
                        "notes": definition["notes"],
                    }
                    detail_rows.append(row)

                    agg = aggregated.setdefault(
                        ndc_row["NDC11"],
                        {
                            "NDC11": ndc_row["NDC11"],
                            "drug_class": class_id,
                            "drug_class_label": definition["label"],
                            "ingredient": [],
                            "rxnorm_ingredient_rxcui": [],
                            "rxnorm_product_rxcui": [],
                            "rxnorm_product_tty": [],
                            "rxnorm_product_name": [],
                            "rxnorm_status": [],
                            "rxnorm_direct_rxcui": [],
                            "rxnorm_start_yyyymm": [],
                            "rxnorm_end_yyyymm": [],
                            "source": RXNORM_SOURCE,
                            "source_url": RXNORM_SOURCE_URL,
                            "notes": definition["notes"],
                        },
                    )
                    for key in [
                        "ingredient",
                        "rxnorm_ingredient_rxcui",
                        "rxnorm_product_rxcui",
                        "rxnorm_product_tty",
                        "rxnorm_product_name",
                        "rxnorm_status",
                        "rxnorm_direct_rxcui",
                        "rxnorm_start_yyyymm",
                        "rxnorm_end_yyyymm",
                    ]:
                        agg[key].append(row[key])

    collapsed = []
    for row in aggregated.values():
        out = dict(row)
        for key, value in row.items():
            if isinstance(value, list):
                out[key] = collapse_values(value)
        collapsed.append(out)
    collapsed.sort(key=lambda row: row["NDC11"])
    detail_rows.sort(key=lambda row: (row["NDC11"], row["ingredient"], row["rxnorm_product_rxcui"]))
    return collapsed, detail_rows


def write_csv(path, rows, fieldnames):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in fieldnames})


def build_drug_files(output_root, retries, sleep_seconds):
    drug_dir = output_root / "drug_ndc"
    fieldnames = [
        "NDC11",
        "drug_class",
        "drug_class_label",
        "ingredient",
        "rxnorm_ingredient_rxcui",
        "rxnorm_product_rxcui",
        "rxnorm_product_tty",
        "rxnorm_product_name",
        "rxnorm_status",
        "rxnorm_direct_rxcui",
        "rxnorm_start_yyyymm",
        "rxnorm_end_yyyymm",
        "source",
        "source_url",
        "notes",
    ]
    all_rows = []
    all_detail_rows = []
    for class_id, definition in DRUG_CLASS_DEFINITIONS.items():
        print("Building drug class:", class_id, file=sys.stderr)
        rows, detail_rows = build_drug_rows(class_id, definition, retries, sleep_seconds)
        write_csv(drug_dir / "{}.csv".format(class_id), rows, fieldnames)
        all_rows.extend(rows)
        all_detail_rows.extend(detail_rows)

    glp1_like = []
    for row in all_rows:
        if row["drug_class"] in {"glp1_ndc", "tirzepatide_ndc"}:
            copied = dict(row)
            copied["drug_class"] = "glp1_like_ndc"
            copied["drug_class_label"] = "GLP-1 RA or GLP-1-like incretin therapy"
            glp1_like.append(copied)
    glp1_like.sort(key=lambda row: row["NDC11"])
    write_csv(drug_dir / "glp1_like_ndc.csv", glp1_like, fieldnames)

    write_csv(drug_dir / "all_diabetes_drug_ndc.csv", sorted(all_rows, key=lambda row: (row["drug_class"], row["NDC11"])), fieldnames)
    write_csv(drug_dir / "all_diabetes_drug_ndc_detail.csv", all_detail_rows, fieldnames)

    manifest_rows = []
    for class_id, definition in DRUG_CLASS_DEFINITIONS.items():
        count = sum(1 for row in all_rows if row["drug_class"] == class_id)
        manifest_rows.append(
            {
                "file": "drug_ndc/{}.csv".format(class_id),
                "concept_type": "drug_ndc",
                "concept_id": class_id,
                "label": definition["label"],
                "row_count": count,
                "source": RXNORM_SOURCE,
                "source_url": RXNORM_SOURCE_URL,
                "notes": definition["notes"],
            }
        )
    manifest_rows.append(
        {
            "file": "drug_ndc/glp1_like_ndc.csv",
            "concept_type": "drug_ndc",
            "concept_id": "glp1_like_ndc",
            "label": "GLP-1 RA or GLP-1-like incretin therapy",
            "row_count": len(glp1_like),
            "source": RXNORM_SOURCE,
            "source_url": RXNORM_SOURCE_URL,
            "notes": "Union of glp1_ndc and tirzepatide_ndc.",
        }
    )
    return manifest_rows


def diagnosis_rows():
    rows = []
    for concept_id, definition in DIAGNOSIS_GROUPS.items():
        for match_type, code, description in definition["rows"]:
            rows.append(
                {
                    "concept_id": concept_id,
                    "concept_label": definition["label"],
                    "coding_system": "ICD10CM",
                    "code": normalize_digits(code) if code[0].isdigit() else code.replace(".", "").upper(),
                    "display_code": code,
                    "match_type": match_type,
                    "code_description": description,
                    "default_claim_rule": definition["rule"],
                    "source": definition["source"],
                    "source_url": definition["source_url"],
                    "notes": "Seed public code list. Normalize claim diagnosis codes by removing decimals and uppercasing before matching.",
                }
            )
    rows.sort(key=lambda row: (row["concept_id"], row["code"], row["match_type"]))
    return rows


def build_diagnosis_files(output_root):
    diagnosis_dir = output_root / "diagnosis_groups"
    fields = [
        "concept_id",
        "concept_label",
        "coding_system",
        "code",
        "display_code",
        "match_type",
        "code_description",
        "default_claim_rule",
        "source",
        "source_url",
        "notes",
    ]
    rows = diagnosis_rows()
    write_csv(diagnosis_dir / "clinical_conditions_icd10cm.csv", rows, fields)
    by_concept = defaultdict(list)
    for row in rows:
        by_concept[row["concept_id"]].append(row)
    for concept_id, concept_rows in by_concept.items():
        write_csv(diagnosis_dir / "{}_icd10cm.csv".format(concept_id), concept_rows, fields)

    manifest_rows = []
    for concept_id, concept_rows in sorted(by_concept.items()):
        manifest_rows.append(
            {
                "file": "diagnosis_groups/{}_icd10cm.csv".format(concept_id),
                "concept_type": "diagnosis_icd10cm",
                "concept_id": concept_id,
                "label": concept_rows[0]["concept_label"],
                "row_count": len(concept_rows),
                "source": collapse_values([row["source"] for row in concept_rows]),
                "source_url": collapse_values([row["source_url"] for row in concept_rows]),
                "notes": "Seed ICD-10-CM code list; review before final analysis.",
            }
        )
    manifest_rows.append(
        {
            "file": "diagnosis_groups/clinical_conditions_icd10cm.csv",
            "concept_type": "diagnosis_icd10cm",
            "concept_id": "all_clinical_conditions",
            "label": "All seed clinical condition groups",
            "row_count": len(rows),
            "source": "Multiple public sources",
            "source_url": collapse_values([AHRQ_ELIX_URL, CCW_URL, CDC_ICD_URL]),
            "notes": "Consolidated file.",
        }
    )
    return manifest_rows


def write_readme(output_root, generated_at):
    text = """# Public Code Lists

Generated at: {generated_at}

These files are public metadata artifacts. They do not contain MarketScan rows,
patient identifiers, service dates, or cost values.

## Drug NDC Files

Files under `drug_ndc/` are generated from the NIH/NLM RxNorm API historical
NDC endpoint. NDCs are stored as CMS-style 11-digit strings in `NDC11`.

Primary drug files:

- `glp1_ndc.csv`
- `tirzepatide_ndc.csv`
- `glp1_like_ndc.csv`
- `dpp4_ndc.csv`
- `metformin_ndc.csv`
- `insulin_ndc.csv`
- `sglt2_ndc.csv`
- `sulfonylurea_ndc.csv`
- `tzd_ndc.csv`
- `other_diabetes_ndc.csv`

RxNorm historical NDCs are appropriate for claims work because MarketScan spans
multiple years and can contain discontinued package NDCs. The FDA NDC Directory
is still useful as a second validation source, but FDA cautions that the
Directory is not a statement of approval, coverage, or reimbursement status.

## Diagnosis Files

Files under `diagnosis_groups/` are ICD-10-CM seed lists using normalized codes
with decimals removed. Apply `match_type = prefix` with starts-with matching and
`match_type = exact` with exact matching after normalizing the claim diagnosis.

These are starting definitions, not final clinical adjudication. For production,
the team should review them against the study protocol, the MarketScan 2021 data
dictionary, and any required validated algorithms.

## MarketScan Mapping Assumptions

Expected raw concepts:

- `D.NDCNUM` or equivalent normalized to `NDC11`
- medical diagnosis fields such as `DX1`, `DX2`, ..., plus `DXVER` if present
- service/fill dates used only inside the approved restricted environment

For 2017-2023 MarketScan, ICD-10-CM should be the main diagnosis coding system,
but use `DXVER` or source documentation to confirm. If any pre-2015 service dates
are included, ICD-9-CM lists are needed too.

## Sources

- NIH/NLM RxNorm API: {rxnorm_url}
- FDA National Drug Code Directory: {fda_url}
- AHRQ HCUP Elixhauser ICD-10-CM software: {ahrq_url}
- CMS Chronic Conditions Data Warehouse algorithms: {ccw_url}
- CDC/NCHS ICD-10-CM: {cdc_url}
""".format(
        generated_at=generated_at,
        rxnorm_url=RXNORM_SOURCE_URL,
        fda_url=FDA_NDC_SOURCE_URL,
        ahrq_url=AHRQ_ELIX_URL,
        ccw_url=CCW_URL,
        cdc_url=CDC_ICD_URL,
    )
    (output_root / "README.md").write_text(text, encoding="utf-8")


def main():
    args = parse_args()
    generated_at = dt.datetime.now(dt.timezone.utc).isoformat()
    args.output_root.mkdir(parents=True, exist_ok=True)

    manifest_rows = []
    if not args.skip_drugs:
        manifest_rows.extend(build_drug_files(args.output_root, args.retries, args.sleep))
    manifest_rows.extend(build_diagnosis_files(args.output_root))
    write_readme(args.output_root, generated_at)

    manifest_fields = [
        "file",
        "concept_type",
        "concept_id",
        "label",
        "row_count",
        "source",
        "source_url",
        "notes",
    ]
    write_csv(args.output_root / "concept_manifest.csv", manifest_rows, manifest_fields)
    print("Wrote public code lists under {}".format(args.output_root))
    return 0


if __name__ == "__main__":
    sys.exit(main())
