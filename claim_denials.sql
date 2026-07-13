CREATE SCHEMA claims;
SET search_path TO claims;

-- =============================================================
-- STEP 1: SCHEMA DESIGN
-- Healthcare Claim Denials Project — PostgreSQL
-- =============================================================

-- -------------------------------------------------------------
-- STAGING LAYER
-- Raw CSVs loaded as-is (all TEXT) so import never fails on messy formatting. Cleaning happens in Step 2, not at load time.
-- -------------------------------------------------------------

DROP TABLE IF EXISTS stg_claims_raw;
CREATE TABLE stg_claims_raw (
	claim_id            TEXT,
    patient_id          TEXT,
    provider_id         TEXT,
    department          TEXT,
    payer_name          TEXT,
    payer_type          TEXT,
    procedure_code      TEXT,
    procedure_desc      TEXT,
    diagnosis_code      TEXT,
    service_date        TEXT,
    submission_date     TEXT,
    billed_amount       TEXT,
    allowed_amount      TEXT,
    paid_amount         TEXT,
    claim_status        TEXT
);
SELECT * FROM stg_claims_raw;

DROP TABLE IF EXISTS stg_denials_raw;
CREATE TABLE stg_denials_raw (
    claim_id             TEXT,
    denial_date          TEXT,
    denial_reason_code   TEXT,
    denial_category      TEXT,
    appealed             TEXT,
    appeal_outcome       TEXT,
    resubmitted_amount   TEXT
);
SELECT * FROM stg_denials_raw;

DROP TABLE IF EXISTS stg_payers_raw;
CREATE TABLE stg_payers_raw (
    payer_name_raw   TEXT,
    payer_type       TEXT
);
SELECT * FROM stg_payers_raw;


-- Quick Sanity Check
SELECT 'stg_claims_raw' AS tbl, COUNT(*) FROM stg_claims_raw
UNION ALL SELECT 'stg_denials_raw', COUNT(*) FROM stg_denials_raw
UNION ALL SELECT 'stg_payers_raw', COUNT(*) FROM stg_payers_raw;


-- -------------------------------------------------------------
-- TARGET LAYER (clean, typed, star-schema style)
-- This is what Step 2's cleaning queries will INSERT INTO, and what Power BI will eventually connect to.
-- -------------------------------------------------------------

DROP TABLE IF EXISTS fact_denials;
DROP TABLE IF EXISTS fact_claims;
DROP TABLE IF EXISTS dim_payer;
DROP TABLE IF EXISTS dim_procedure;
DROP TABLE IF EXISTS dim_denial_category;

CREATE TABLE dim_payer (
    payer_id        SERIAL PRIMARY KEY,
    payer_name      TEXT NOT NULL UNIQUE,   -- standardized name
    payer_type      TEXT                    -- Commercial / Government
);

CREATE TABLE dim_procedure (
    procedure_code   TEXT PRIMARY KEY,      -- CPT code, standardized
    procedure_desc   TEXT
);

CREATE TABLE dim_denial_category (
    category_id      SERIAL PRIMARY KEY,
    category_name    TEXT NOT NULL UNIQUE   -- standardized (Eligibility, Authorization, etc.)
);

CREATE TABLE fact_claims (
    claim_id           TEXT PRIMARY KEY,
    patient_id         TEXT,
    provider_id        TEXT,
    department         TEXT,
    payer_id           INT REFERENCES dim_payer(payer_id),
    procedure_code     TEXT REFERENCES dim_procedure(procedure_code),
    diagnosis_code     TEXT,
    service_date       DATE,
    submission_date    DATE,
    billed_amount      NUMERIC(10,2),
    allowed_amount     NUMERIC(10,2),
    paid_amount        NUMERIC(10,2),
    claim_status       TEXT                -- Paid / Denied / Pending (standardized)
);

CREATE TABLE fact_denials (
    denial_id             SERIAL PRIMARY KEY,
    claim_id              TEXT REFERENCES fact_claims(claim_id),
    denial_date           DATE,
    denial_reason_code    TEXT,
    category_id           INT REFERENCES dim_denial_category(category_id),
    appealed              BOOLEAN,
    appeal_outcome        TEXT,             -- Approved / Denied / Pending
    resubmitted_amount    NUMERIC(10,2)
);

-- Quick sanity check
SELECT 'fact_claims' AS tbl, COUNT(*) FROM fact_claims
   UNION ALL SELECT 'fact_denials', COUNT(*) FROM fact_denials
   UNION ALL SELECT 'dim_payer', COUNT(*) FROM dim_payer
   UNION ALL SELECT 'dim_procedure', COUNT(*) FROM dim_procedure
   UNION ALL SELECT 'dim_denial_category', COUNT(*) FROM dim_denial_category;


-- =============================================================
-- STEP 2: DATA CLEANING
-- Transforms staging (raw, messy) tables into the clean target star schema.
-- =============================================================

-- -------------------------------------------------------------
-- 2A. dim_denial_category
-- Issue: same category has multiple spellings/casing
-- (e.g. "Prior Auth Required", "auth", "AUTH REQUIRED")
-- Fix: pattern-match keywords into 6 canonical categories
-- -------------------------------------------------------------
INSERT INTO dim_denial_category (category_name)
SELECT DISTINCT
    CASE UPPER(TRIM(denial_category))
        WHEN 'ELIGIBILITY'         THEN 'Eligibility'
        WHEN 'AUTHORIZATION'       THEN 'Authorization'
        WHEN 'CODING ERROR'        THEN 'Coding Error'
        WHEN 'TIMELY FILING'       THEN 'Timely Filing'
        WHEN 'MEDICAL NECESSITY'   THEN 'Medical Necessity'
        WHEN 'DUPLICATE CLAIM'     THEN 'Duplicate Claim'
        ELSE 'Other/Unclassified'
    END
FROM stg_denials_raw
WHERE denial_category IS NOT NULL AND TRIM(denial_category) <> '';

SELECT * FROM dim_denial_category;


-- -------------------------------------------------------------
-- 2B. dim_payer
-- Issue: same payer appears in different casing/whitespace
-- ("Aetna" / "AETNA" / "aetna" / "  Aetna  ")
-- Fix: normalize case, map to one canonical spelling
-- -------------------------------------------------------------
INSERT INTO dim_payer (payer_name, payer_type)
SELECT DISTINCT
    canonical_name,
    CASE WHEN canonical_name IN ('Medicare','Medicaid') THEN 'Government' ELSE 'Commercial' END
FROM (
    SELECT
        CASE UPPER(TRIM(payer_name))
            WHEN 'AETNA'                    THEN 'Aetna'
            WHEN 'UNITEDHEALTHCARE'         THEN 'UnitedHealthcare'
            WHEN 'CIGNA'                    THEN 'Cigna'
            WHEN 'MEDICARE'                 THEN 'Medicare'
            WHEN 'MEDICAID'                 THEN 'Medicaid'
            WHEN 'BLUECROSS BLUESHIELD'     THEN 'BlueCross BlueShield'
            WHEN 'HUMANA'                   THEN 'Humana'
            ELSE 'Unknown Payer'
        END AS canonical_name
    FROM stg_claims_raw
) x;

SELECT * FROM dim_payer;


-- -------------------------------------------------------------
-- 2C. dim_procedure
-- Issue: some codes have a trailing ".0" (imported as float)
-- Fix: strip ".0" suffix, trim, dedupe
-- -------------------------------------------------------------
INSERT INTO dim_procedure (procedure_code, procedure_desc)
SELECT DISTINCT
    REGEXP_REPLACE(TRIM(procedure_code), '\.0$', ''),
    MAX(procedure_desc)
FROM stg_claims_raw
WHERE procedure_code IS NOT NULL AND TRIM(procedure_code) <> ''
GROUP BY REGEXP_REPLACE(TRIM(procedure_code), '\.0$', '');

SELECT * FROM dim_procedure;


-- -------------------------------------------------------------
-- 2D. fact_claims
-- Issues fixed here:
--   - duplicate claim_id rows -> keep one (ROW_NUMBER dedupe)
--   - two date formats (ISO / US) -> pattern-matched TO_DATE
--   - "$" sign in amounts -> stripped, cast to NUMERIC
--   - inconsistent text casing -> INITCAP/TRIM
--   - payer_name text -> payer_id via dim_payer join
-- -------------------------------------------------------------
WITH cleaned AS (
    SELECT
        TRIM(claim_id) AS claim_id,
        TRIM(patient_id) AS patient_id,
        TRIM(provider_id) AS provider_id,
        INITCAP(TRIM(department)) AS department,

        CASE UPPER(TRIM(payer_name))
            WHEN 'AETNA'                THEN 'Aetna'
            WHEN 'UNITEDHEALTHCARE'     THEN 'UnitedHealthcare'
            WHEN 'CIGNA'                THEN 'Cigna'
            WHEN 'MEDICARE'             THEN 'Medicare'
            WHEN 'MEDICAID'             THEN 'Medicaid'
            WHEN 'BLUECROSS BLUESHIELD' THEN 'BlueCross BlueShield'
            WHEN 'HUMANA'               THEN 'Humana'
            ELSE 'Unknown Payer'
        END AS payer_canonical,

        REGEXP_REPLACE(TRIM(procedure_code), '\.0$', '') AS procedure_code,
        NULLIF(TRIM(diagnosis_code), '') AS diagnosis_code,

        CASE
            WHEN service_date ~ '^\d{4}-\d{2}-\d{2}$' THEN TO_DATE(service_date, 'YYYY-MM-DD')
            WHEN service_date ~ '^\d{2}/\d{2}/\d{4}$' THEN TO_DATE(service_date, 'MM/DD/YYYY')
            ELSE NULL
        END AS service_date,

        CASE
            WHEN submission_date ~ '^\d{4}-\d{2}-\d{2}$' THEN TO_DATE(submission_date, 'YYYY-MM-DD')
            WHEN submission_date ~ '^\d{2}/\d{2}/\d{4}$' THEN TO_DATE(submission_date, 'MM/DD/YYYY')
            ELSE NULL
        END AS submission_date,

        NULLIF(REPLACE(TRIM(billed_amount), '$', ''), '')::NUMERIC AS billed_amount,
        NULLIF(REPLACE(TRIM(allowed_amount), '$', ''), '')::NUMERIC AS allowed_amount,
        NULLIF(REPLACE(TRIM(paid_amount), '$', ''), '')::NUMERIC AS paid_amount,

        INITCAP(TRIM(claim_status)) AS claim_status,

        ROW_NUMBER() OVER (
            PARTITION BY TRIM(claim_id)
            ORDER BY submission_date
        ) AS rn
    FROM stg_claims_raw
    WHERE claim_id IS NOT NULL AND TRIM(claim_id) <> ''
)
INSERT INTO fact_claims (
    claim_id, patient_id, provider_id, department, payer_id,
    procedure_code, diagnosis_code, service_date, submission_date,
    billed_amount, allowed_amount, paid_amount, claim_status
)
SELECT
    c.claim_id, c.patient_id, c.provider_id, c.department, p.payer_id,
    c.procedure_code, c.diagnosis_code, c.service_date, c.submission_date,
    c.billed_amount, c.allowed_amount, c.paid_amount, c.claim_status
FROM cleaned c
LEFT JOIN dim_payer p ON p.payer_name = c.payer_canonical
WHERE c.rn = 1;   -- drop duplicate claim_id rows, keep first

SELECT * FROM fact_claims;


-- -------------------------------------------------------------
-- 2E. fact_denials
-- Issues fixed here:
--   - two date formats -> same pattern-match approach as above
--   - Y/N text -> normalized to BOOLEAN
--   - denial_category casing -> category_id via dim_denial_category join
-- -------------------------------------------------------------
WITH cleaned_denials AS (
    SELECT
        TRIM(d.claim_id) AS claim_id,

        CASE
            WHEN d.denial_date ~ '^\d{4}-\d{2}-\d{2}$' THEN TO_DATE(d.denial_date, 'YYYY-MM-DD')
            WHEN d.denial_date ~ '^\d{2}/\d{2}/\d{4}$' THEN TO_DATE(d.denial_date, 'MM/DD/YYYY')
            ELSE NULL
        END AS denial_date,

        NULLIF(TRIM(d.denial_reason_code), '') AS denial_reason_code,

        CASE UPPER(TRIM(d.denial_category))
            WHEN 'ELIGIBILITY'         THEN 'Eligibility'
            WHEN 'AUTHORIZATION'       THEN 'Authorization'
            WHEN 'CODING ERROR'        THEN 'Coding Error'
            WHEN 'TIMELY FILING'       THEN 'Timely Filing'
            WHEN 'MEDICAL NECESSITY'   THEN 'Medical Necessity'
            WHEN 'DUPLICATE CLAIM'     THEN 'Duplicate Claim'
            ELSE 'Other/Unclassified'
        END AS category_name,

        CASE
            WHEN UPPER(TRIM(d.appealed)) = 'Y' THEN TRUE
            WHEN UPPER(TRIM(d.appealed)) = 'N' THEN FALSE
            ELSE NULL
        END AS appealed,

        NULLIF(TRIM(d.appeal_outcome), '') AS appeal_outcome,
        NULLIF(REPLACE(TRIM(d.resubmitted_amount), '$', ''), '')::NUMERIC AS resubmitted_amount
    FROM stg_denials_raw d
    INNER JOIN fact_claims fc ON fc.claim_id = TRIM(d.claim_id)
)
INSERT INTO fact_denials (
    claim_id, denial_date, denial_reason_code, category_id,
    appealed, appeal_outcome, resubmitted_amount
)
SELECT
    cd.claim_id, cd.denial_date, cd.denial_reason_code, dc.category_id,
    cd.appealed, cd.appeal_outcome, cd.resubmitted_amount
FROM cleaned_denials cd
LEFT JOIN dim_denial_category dc ON dc.category_name = cd.category_name;

SELECT * FROM fact_denials;

-- Quick sanity check
SELECT 'fact_claims' AS tbl, COUNT(*) FROM fact_claims
UNION ALL SELECT 'fact_denials', COUNT(*) FROM fact_denials
UNION ALL SELECT 'dim_payer', COUNT(*) FROM dim_payer
UNION ALL SELECT 'dim_procedure', COUNT(*) FROM dim_procedure
UNION ALL SELECT 'dim_denial_category', COUNT(*) FROM dim_denial_category;

-- 1. Any claim where allowed or paid exceeds billed? (shouldn't happen)
SELECT claim_id, billed_amount, allowed_amount, paid_amount
FROM fact_claims
WHERE allowed_amount > billed_amount OR paid_amount > billed_amount;

-- 2. Every claim marked 'Denied' should have a matching fact_denials row, and vice versa
SELECT fc.claim_id, fc.claim_status
FROM fact_claims fc
LEFT JOIN fact_denials fd ON fc.claim_id = fd.claim_id
WHERE fc.claim_status = 'Denied' AND fd.claim_id IS NULL;

-- 3. Any denial pointing to a claim NOT marked Denied?
SELECT fd.claim_id, fc.claim_status
FROM fact_denials fd
JOIN fact_claims fc ON fc.claim_id = fd.claim_id
WHERE fc.claim_status <> 'Denied';

-- 4. Null check on fields that should always be populated
SELECT COUNT(*) FILTER (WHERE payer_id IS NULL) AS null_payer,
       COUNT(*) FILTER (WHERE service_date IS NULL) AS null_service_date,
       COUNT(*) FILTER (WHERE claim_status IS NULL) AS null_status
FROM fact_claims;


-- =============================================================
-- STEP 4: ANALYSIS QUERIES
-- =============================================================

-- -------------------------------------------------------------
-- 4A. Overall denial rate — by claim count AND by dollar amount
-- Dollar-weighted rate usually matters more to the business than raw count, since a few high-value denials can outweigh many small ones.
-- -------------------------------------------------------------
SELECT
    COUNT(*) AS total_claims,
    COUNT(*) FILTER (WHERE claim_status = 'Denied') AS denied_claims,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE claim_status = 'Denied') / COUNT(*), 2
    ) AS denial_rate_pct,
    SUM(billed_amount) AS total_billed,
    SUM(billed_amount) FILTER (WHERE claim_status = 'Denied') AS total_billed_denied,
    ROUND(
        100.0 * SUM(billed_amount) FILTER (WHERE claim_status = 'Denied') / SUM(billed_amount), 2
    ) AS denial_rate_pct_by_dollar
FROM fact_claims;

-- -------------------------------------------------------------
-- 4B. Denial rate by payer
-- Answers: which payers deny the most, both by rate and by $ at risk
-- -------------------------------------------------------------
SELECT
    p.payer_name,
    p.payer_type,
    COUNT(*) AS total_claims,
    COUNT(*) FILTER (WHERE c.claim_status = 'Denied')                              AS denied_claims,
    ROUND(100.0 * COUNT(*) FILTER (WHERE c.claim_status = 'Denied') / COUNT(*), 2) AS denial_rate_pct,
    SUM(c.billed_amount) FILTER (WHERE c.claim_status = 'Denied')                  AS dollars_denied
FROM fact_claims c
JOIN dim_payer p ON p.payer_id = c.payer_id
GROUP BY p.payer_name, p.payer_type
ORDER BY denial_rate_pct DESC;

-- -------------------------------------------------------------
-- 4C. Denial rate by root cause category
-- Answers: what's actually causing denials - this is the "so what do we fix" query
-- -------------------------------------------------------------
SELECT
    dc.category_name,
    COUNT(*)                                           AS denial_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_all_denials,
    SUM(fc.billed_amount)                              AS dollars_denied
FROM fact_denials fd
JOIN dim_denial_category dc ON dc.category_id = fd.category_id
JOIN fact_claims fc ON fc.claim_id = fd.claim_id
GROUP BY dc.category_name
ORDER BY dollars_denied DESC;

-- -------------------------------------------------------------
-- 4D. Top procedures driving denials
-- Answers: which specific services are getting denied most often
-- -------------------------------------------------------------
SELECT
    dp.procedure_code,
    dp.procedure_desc,
    COUNT(*)                    												   AS total_claims,
    COUNT(*) FILTER (WHERE c.claim_status = 'Denied')                              AS denied_claims,
    ROUND(100.0 * COUNT(*) FILTER (WHERE c.claim_status = 'Denied') / COUNT(*), 2) AS denial_rate_pct
FROM fact_claims c
JOIN dim_procedure dp ON dp.procedure_code = c.procedure_code
GROUP BY dp.procedure_code, dp.procedure_desc
ORDER BY denial_rate_pct DESC;

-- -------------------------------------------------------------
-- 4E. Denial rate by department
-- Answers: which departments have the biggest denial exposure
-- -------------------------------------------------------------
SELECT
    department,
    COUNT(*) AS total_claims,
    COUNT(*) FILTER (WHERE claim_status = 'Denied')                              AS denied_claims,
    ROUND(100.0 * COUNT(*) FILTER (WHERE claim_status = 'Denied') / COUNT(*), 2) AS denial_rate_pct,
    SUM(billed_amount) FILTER (WHERE claim_status = 'Denied')                    AS dollars_denied
FROM fact_claims
GROUP BY department
ORDER BY dollars_denied DESC;

-- -------------------------------------------------------------
-- 4F. Appeal recovery rate
-- Answers: of the money that gets denied, how much do we actually recover through appeals, and how often is appealing worth it
-- -------------------------------------------------------------
SELECT
    COUNT(*)                                                             AS total_denials,
    COUNT(*) FILTER (WHERE appealed = TRUE)                              AS appealed_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE appealed = TRUE) / COUNT(*), 2) AS appeal_rate_pct,
    COUNT(*) FILTER (WHERE appeal_outcome = 'Approved')                  AS appeals_won,
    ROUND(100.0 * COUNT(*) FILTER (WHERE appeal_outcome = 'Approved')
        / NULLIF(COUNT(*) FILTER (WHERE appealed = TRUE), 0), 2)         AS appeal_success_rate_pct,
    SUM(resubmitted_amount) FILTER (WHERE appeal_outcome = 'Approved')   AS dollars_recovered
FROM fact_denials;

-- -------------------------------------------------------------
-- 4G. Denial trend over time (monthly)
-- Note: excludes ~287 claims with missing service_date 
-- -------------------------------------------------------------
SELECT
    DATE_TRUNC('month', service_date)                                            AS claim_month,
    COUNT(*)                                                                     AS total_claims,
    COUNT(*) FILTER (WHERE claim_status = 'Denied')                              AS denied_claims,
    ROUND(100.0 * COUNT(*) FILTER (WHERE claim_status = 'Denied') / COUNT(*), 2) AS denial_rate_pct
FROM fact_claims
WHERE service_date IS NOT NULL
GROUP BY DATE_TRUNC('month', service_date)
ORDER BY claim_month;
