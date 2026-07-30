-- ============================================================
-- Revenue Cycle Analytics — SQL analysis
-- Dialect: SQLite (portable; minor tweaks for Postgres/MySQL noted)
-- Data: synthetic hospital claims (revenue_cycle_claims.csv)
--
-- Setup (SQLite CLI):
--   sqlite3 revcycle.db
--   .mode csv
--   .import revenue_cycle_claims.csv claims
--   -- then run the queries below (or: .read revenue_cycle_analysis.sql)
-- ============================================================


-- 1) EXECUTIVE KPI SNAPSHOT ----------------------------------
-- One row summarizing the whole revenue cycle.
SELECT
  COUNT(*)                                                        AS total_claims,
  ROUND(100.0 * SUM(claim_status='Denied')      / COUNT(*), 1)    AS denial_rate_pct,
  ROUND(100.0 * SUM(first_pass_paid)            / COUNT(*), 1)    AS first_pass_rate_pct,
  ROUND(SUM(paid_amount) * 100.0
        / (SUM(charge_amount) - SUM(contractual_adjustment)), 1)  AS net_collection_rate_pct,
  ROUND(SUM(pos_collected) * 100.0
        / SUM(patient_responsibility), 1)                         AS pos_collection_rate_pct,
  ROUND(AVG(CASE WHEN claim_status <> 'Paid' THEN days_in_ar END), 1) AS avg_days_in_ar_open
FROM claims;


-- 2) DENIAL RATE BY PAYER ------------------------------------
-- Which payers deny most? (targets payer-specific process fixes)
SELECT
  payer,
  COUNT(*)                                            AS claims,
  SUM(claim_status='Denied')                          AS denials,
  ROUND(100.0 * SUM(claim_status='Denied')/COUNT(*),1) AS denial_rate_pct,
  ROUND(SUM(CASE WHEN claim_status='Denied'
                 THEN expected_reimbursement END), 0)  AS denied_dollars
FROM claims
GROUP BY payer
ORDER BY denial_rate_pct DESC;


-- 3) TOP DENIAL REASONS (revenue-leakage prioritization) -----
-- Where to focus appeals + front-end fixes. Prior-auth and
-- eligibility denials are preventable at Patient Access.
SELECT
  denial_reason,
  COUNT(*)                                             AS denials,
  ROUND(100.0 * COUNT(*)
        / SUM(COUNT(*)) OVER (), 1)                    AS pct_of_denials,
  ROUND(SUM(expected_reimbursement), 0)               AS dollars_at_risk
FROM claims
WHERE claim_status = 'Denied'
GROUP BY denial_reason
ORDER BY dollars_at_risk DESC;


-- 4) AR AGING BUCKETS ----------------------------------------
-- Dollars sitting in accounts receivable by age. 90+ is the
-- danger zone (write-off / bad-debt risk).
SELECT
  CASE
    WHEN days_in_ar BETWEEN 0  AND 30 THEN '0-30'
    WHEN days_in_ar BETWEEN 31 AND 60 THEN '31-60'
    WHEN days_in_ar BETWEEN 61 AND 90 THEN '61-90'
    ELSE '90+'
  END AS ar_bucket,
  COUNT(*)                              AS open_claims,
  ROUND(SUM(expected_reimbursement), 0) AS ar_dollars
FROM claims
WHERE claim_status <> 'Paid'
GROUP BY ar_bucket
ORDER BY
  CASE ar_bucket WHEN '0-30' THEN 1 WHEN '31-60' THEN 2
                 WHEN '61-90' THEN 3 ELSE 4 END;


-- 5) POINT-OF-SERVICE COLLECTION RATE BY DEPARTMENT ----------
-- Patient Access KPI. Emergency typically collects least at POS
-- because care precedes registration/financial clearance.
SELECT
  department,
  ROUND(SUM(pos_collected), 0)              AS collected_at_pos,
  ROUND(SUM(patient_responsibility), 0)     AS patient_owed,
  ROUND(100.0 * SUM(pos_collected)
        / SUM(patient_responsibility), 1)   AS pos_collection_rate_pct
FROM claims
GROUP BY department
ORDER BY pos_collection_rate_pct ASC;


-- 6) CHARGE LAG BY DEPARTMENT --------------------------------
-- Days from service to charge posting. Long lag delays billing
-- and inflates days-in-AR — a charge-capture / HIM issue.
SELECT
  department,
  ROUND(AVG(charge_lag_days), 1) AS avg_charge_lag_days,
  MAX(charge_lag_days)           AS worst_case_days
FROM claims
GROUP BY department
ORDER BY avg_charge_lag_days DESC;


-- 7) PREVENTABLE-DENIAL DOLLARS (the headline number) --------
-- Prior-auth + eligibility denials are preventable upstream.
-- This is the "if we fixed Patient Access, we'd recover $X" line.
SELECT
  ROUND(SUM(expected_reimbursement), 0) AS preventable_denied_dollars,
  COUNT(*)                              AS preventable_denials
FROM claims
WHERE claim_status = 'Denied'
  AND denial_reason IN (
      'Missing/Invalid Prior Authorization',
      'Eligibility / Coverage Terminated'
  );
