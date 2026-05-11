# Public Code Lists

Generated at: 2026-05-06T16:29:01.908429+00:00

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

- NIH/NLM RxNorm API: https://lhncbc.nlm.nih.gov/RxNav/APIs/api-RxNorm.getAllHistoricalNDCs.html
- FDA National Drug Code Directory: https://www.fda.gov/drugs/drug-approvals-and-databases/national-drug-code-directory
- AHRQ HCUP Elixhauser ICD-10-CM software: https://hcup-us.ahrq.gov/toolssoftware/comorbidityicd10/comorbidity_icd10.jsp
- CMS Chronic Conditions Data Warehouse algorithms: https://www2.ccwdata.org/web/guest/condition-categories
- CDC/NCHS ICD-10-CM: https://www.cdc.gov/nchs/icd/icd-10-cm/index.html
