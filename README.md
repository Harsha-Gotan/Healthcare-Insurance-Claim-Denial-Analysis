# Healthcare-Insurance-Claim-Denial-Analysis
A SQL + Power BI analytics project identifying the root causes of healthcare claim denials, quantifying their financial impact, and surfacing actionable recovery opportunities - approached from a revenue-cycle-management (RCM) and financial-analyst perspective.

---

## Business Problem

Claim denials are one of the largest sources of delayed and lost revenue for healthcare providers. Every denied claim means staff time spent investigating, correcting, and resubmitting - or, if never appealed, revenue written off entirely. Industry benchmarks put initial denial rates around 10-15%, and a meaningful share of denied revenue is typically never recovered simply because claims are never contested.

This project analyzes a claims dataset to answer the questions a healthcare revenue cycle or BI team would actually be asked to solve:

- What percentage of claims are denied, and how much revenue is at risk?
- Which payers and departments carry the highest denial exposure?
- What are the actual root causes driving denials - and which ones are worth fixing first?
- How effective is the appeals process, and where's the biggest untapped recovery opportunity?

## Tech Stack

| Tool | Purpose |
|---|---|
| **PostgreSQL** | Relational database, schema design, data cleaning/transformation, analysis |
| **SQL** | Staging → cleaning → star schema ETL pipeline, aggregation & analysis queries |
| **Power BI** | Data modeling, DAX measures, interactive dashboard, slicers |

## Data Overview

Real hospital claims data is never publicly available due to HIPAA, so this project uses a **synthetically generated dataset** (~6,000 claims, ~750 denial records) built to mirror realistic claim/denial patterns - including a realistic ~12–13% overall denial rate, payer-specific denial skew (government payers denying more heavily on eligibility grounds, consistent with real-world patterns), and common data quality issues that required genuine cleaning before analysis: missing values, inconsistent text casing/whitespace, duplicate records, and mixed date/currency formatting.

**Source files:**
- `claims_raw.csv` - claim-level data: payer, procedure, provider, department, service/submission dates, billed/allowed/paid amounts, claim status
- `denials_raw.csv` - denial-level data: denial reason code, denial category, appeal status, appeal outcome, resubmitted amount
- `payers_raw.csv` - payer reference data

## Methodology

**1. Schema design** - Designed a star schema in PostgreSQL: two fact tables (`fact_claims`, `fact_denials`, capturing claim-level and denial-level events respectively) and three dimension tables (`dim_payer`, `dim_procedure`, `dim_denial_category`). A staging layer holds raw CSV data as-is before any transformation, keeping the original data intact and separate from the cleaned target tables.

**2. Data cleaning (SQL)** - Transformed staging data into the clean target schema:
- Standardized inconsistent text casing and whitespace across payer names, denial categories, and claim status values
- Parsed inconsistent date formats into proper `DATE` types
- Cleaned currency fields (stripped `$` symbols, cast text to `NUMERIC`)
- Deduplicated claim records using window functions
- Normalized inconsistent boolean representations for the appeal flag
- Identified ~5% of records with missing service dates and explicitly excluded them from time-based trend analysis rather than imputing fabricated dates — documented as a known data limitation

**3. Validation / QA** - Before trusting the cleaned data for analysis, ran logical consistency checks: confirmed no claim had `allowed_amount` or `paid_amount` exceeding `billed_amount`, confirmed every claim marked "Denied" had a corresponding row in the denials table (and vice versa), and quantified remaining nulls by field.

**4. Analysis (SQL)** - Wrote aggregation queries covering: overall denial rate (by claim count and by dollar value), denial rate by payer, root cause breakdown by category, denial rate by procedure and department, and appeal recovery metrics (appeal rate, success rate, dollars recovered).

**5. Dashboard (Power BI)** - Connected directly to the cleaned PostgreSQL tables, built a relational star-schema data model, wrote DAX measures that reproduce the validated SQL logic, and built a 2-page interactive dashboard with synced slicers for date range, payer, and denial category.

## Data Model

<img width="1331" height="777" alt="image" src="https://github.com/user-attachments/assets/6856b6c4-5ba5-4318-8415-be8292d6efc2" />

- `fact_claims` - one row per claim; measures: `billed_amount`, `allowed_amount`, `paid_amount`; attributes: payer, procedure, department, dates, status
- `fact_denials` - one row per denial event, linked back to its parent claim; measures: `resubmitted_amount`; attributes: denial category, reason code, appeal status/outcome
- Dimension tables provide standardized, deduplicated lookup values for filtering and grouping in both SQL and Power BI

## Dashboard Walkthrough

### Page 1 — Executive Summary
*Denial trends, root causes, and payer performance at a glance*

- **KPI cards** — Total Claims, Denial Rate %, Total Billed Denied, Appeal Success Rate % — the four numbers a stakeholder needs before anything else
- **Denial Rate Trend by Month** (line chart) - tracks denial rate over a 12-month period, revealing whether the problem is stable, worsening, or improving over time
- **Denials by Root Cause** (horizontal bar chart) - ranks denial categories (Authorization, Eligibility, Coding Error, Medical Necessity, Timely Filing, Duplicate Claim) by volume, immediately surfacing where the biggest problems concentrate
- **Denial Rate by Payer** (horizontal bar chart) - ranks all 7 payers by denial rate percentage, exposing which payer relationships need the most attention
- **Narrative callout** - a one-line summary translating the headline numbers into a plain-language takeaway

*Interactivity:* Quarter/Month, denial category, and payer slicers filter all visuals on the page simultaneously.

### Page 2 — Financial Recovery & Drill-down
*Where denied revenue goes, and the case for appealing more of it*

- **KPI cards** - Total Denials, Appealed Count, Appeal Rate %, Appeals Won, Dollars Recovered - laid out to show the appeal funnel numerically at a glance (denials → appealed → won → recovered)
- **Denial Rate by Procedure** (table) - every procedure code with total claims, denied claims, and denial rate %, sorted descending, with a totals row - lets a viewer drill from the high-level story down to specific services
- **Payer × Denial Category matrix** - a cross-tab showing denial counts for each payer broken out by root cause category, answering "is Medicaid's high denial rate driven by one specific issue, or spread across causes?" without needing a separate chart per payer
- **Dollars Recovered by Payer Type** (donut chart) - splits total recovered appeal dollars between Commercial and Government payers, adding a dimension not covered elsewhere on the dashboard
- **Recommendation callout** - ties the page's numbers directly to a specific, actionable next step

*Interactivity:* same synced slicers as Page 1, so any filter selection (e.g., "Medicaid only") applies consistently across both pages.

## Key Findings

- **Overall denial rate: 12.63%** by claim count, **12.32% by dollar value** - $2.26M of $18.37M billed was denied. The close alignment between count-based and dollar-based rates indicates denials aren't concentrated in unusually high- or low-value claims.
- **Medicaid has the highest denial rate at 19.26%**, notably above every commercial payer - Humana is next highest at 15.23%, Medicare is lowest at 8.50%.
- **Authorization and Eligibility are the top two root causes**, together accounting for roughly **48% of all denied dollars** ($1.05M of $2.26M combined) - a concentrated, addressable problem rather than a diffuse one spread evenly across many causes.
- **Only 33.8% of denials are ever appealed**, despite a **42.6% appeal success rate** on the ones that are - meaning the majority of potentially recoverable revenue is never contested at all.
- Appeal dollar recovery splits roughly **59% Commercial / 41% Government** by payer type.
- Denial rates by department and procedure are fairly evenly distributed (10-16% range) - this isn't one broken department or one problem service, it's two systemic root causes cutting across the organization.

## Business Impact

Translating the findings into what they mean financially:

- **$2.26M in billed revenue is currently at risk** from denials across the analyzed period.
- **Nearly half of that ($1.05M) traces back to just two fixable causes** - Authorization and Eligibility - meaning targeted process fixes (not organization-wide overhauls) could meaningfully move the needle.
- **The appeal gap represents a near-term, low-effort recovery lever**: if the ~66% of denials currently never appealed were appealed at the existing 42.6% success rate, that implies a substantial share of the $2.26M currently written off could instead be recovered - without needing to fix the underlying denial causes first.

## Recommendations

1. **Prioritize Authorization and Eligibility workflows first.** These two categories represent the highest-leverage fix — implementing real-time eligibility verification at intake and stronger pre-authorization checks would directly target nearly half of all denied revenue.
2. **Increase appeal volume, especially on Authorization denials.** With a proven 42.6% success rate but only a third of denials appealed, expanding appeal coverage is a low-risk, high-return way to recover revenue that's currently being left on the table.
3. **Investigate Medicaid-specific denial workflows.** Its denial rate is meaningfully higher than every other payer, suggesting a payer-specific process gap (e.g., eligibility verification timing, authorization requirements unique to Medicaid) rather than a general billing issue.

## Skills Demonstrated

- Relational database design (star schema, fact/dimension modeling)
- SQL data cleaning: text standardization, date parsing, deduplication, type casting
- Data validation and QA methodology
- DAX measure design (CALCULATE, DIVIDE, FILTER context)
- Power BI dashboard design: KPI cards, trend analysis, cross-tab matrices, synced slicers
- Translating technical findings into business recommendations with quantified financial impact
