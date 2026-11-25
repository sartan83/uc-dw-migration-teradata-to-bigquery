-- Source: dml/scripts/bteq_extract_report.btq
-- BigQuery multi-statement script, run monthly by the orchestrator.
--   .EXPORT DATA / REPORT FILE=...  -> EXPORT DATA to GCS (CSV, '|' delimited).
--                                      Teradata FORMAT/CHAR() padding is a
--                                      presentation concern: amounts are exported
--                                      as plain decimals; fixed-width .rpt layout,
--                                      if regulators still need it, is rendered
--                                      by the orchestrator from the CSV.
--   ORDER BY in exports             -> kept; single-file export (no '*' in URI
--                                      would be required for >1 GB, which these
--                                      monthly extracts are not)
--   ADD_MONTHS(CURRENT_DATE, -1)    -> DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH)
--   EXEC AML_SCREENING              -> three EXPORT DATA statements, one per TVF
--   .IF ACTIVITYCOUNT = 0 .GOTO NODATA -> count check + RETURN with WARN log
-- The Teradata script tested ACTIVITYCOUNT after .EXPORT RESET, i.e. after the
-- large-transaction export; the check here runs before it to avoid an empty file.
-- Query parameter: @gcs_prefix, e.g. 'gs://<bucket>/exports'
-- The source selected REFERENCE_NUMBER, which VW_REGULATORY_LARGE_TRANSACTIONS
-- does not expose; it is joined back from fact_transaction here.
DECLARE v_period_start DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH);
DECLARE v_prev_month_key INT64 DEFAULT
    EXTRACT(YEAR FROM v_period_start) * 100 + EXTRACT(MONTH FROM v_period_start);
DECLARE v_large_txn_rows INT64;

SET v_large_txn_rows = (
    SELECT COUNT(*) FROM banking_dw.vw_regulatory_large_transactions
    WHERE TRANSACTION_DATE BETWEEN v_period_start AND CURRENT_DATE());

IF v_large_txn_rows = 0 THEN
    INSERT INTO banking_dw.etl_log (PROCEDURE_NAME, BATCH_ID, LOG_LEVEL, LOG_MESSAGE, LOG_TS)
    VALUES ('MONTHLY_EXTRACT', NULL, 'WARN',
            'WARNING: No large transactions found for the reporting period.',
            CURRENT_TIMESTAMP());
    RETURN;
END IF;

-- Export 1: Large Transaction Report (regulatory submission)
EXECUTE IMMEDIATE FORMAT("""
EXPORT DATA OPTIONS (uri = '%s/large_txn_report_%d_*.csv', format = 'CSV',
                     overwrite = TRUE, header = TRUE, field_delimiter = '|') AS
SELECT
    r.TRANSACTION_ID, r.TRANSACTION_DATE, r.CUSTOMER_ID, r.FIRST_NAME, r.LAST_NAME,
    r.KYC_STATUS, r.ACCOUNT_ID, r.ACCOUNT_TYPE, r.TRANSACTION_TYPE,
    r.TRANSACTION_AMOUNT, r.TRANSACTION_CURRENCY, r.BASE_CURRENCY_AMOUNT,
    r.IS_INTERNATIONAL, r.REPORTING_CATEGORY, r.MERCHANT_NAME, ft.REFERENCE_NUMBER
FROM banking_dw.vw_regulatory_large_transactions r
LEFT JOIN banking_dw.fact_transaction ft
    ON ft.TRANSACTION_ID = r.TRANSACTION_ID
   AND ft.TRANSACTION_DATE = r.TRANSACTION_DATE
WHERE r.TRANSACTION_DATE BETWEEN DATE '%t' AND CURRENT_DATE()
ORDER BY r.TRANSACTION_DATE, r.TRANSACTION_ID
""", @gcs_prefix, v_prev_month_key, v_period_start);

-- Export 2: Branch Performance Summary
EXECUTE IMMEDIATE FORMAT("""
EXPORT DATA OPTIONS (uri = '%s/branch_performance_%d_*.csv', format = 'CSV',
                     overwrite = TRUE, header = TRUE, field_delimiter = '|') AS
SELECT
    BRANCH_NAME AS Branch,
    REGION AS Region,
    MONTH_LABEL AS Month,
    ACCOUNTS_SERVICED AS Accounts,
    ROUND(TOTAL_DEPOSITS, 2) AS Total_Deposits_NOK,
    ROUND(TOTAL_FEES_EARNED, 2) AS Fees_Earned,
    REGION_DEPOSIT_RANK AS Rank,
    ROUND(PCT_OF_REGION_DEPOSITS, 2) AS Pct_Region
FROM banking_dw.vw_branch_monthly_performance
WHERE SNAPSHOT_MONTH_KEY = %d
ORDER BY REGION, REGION_DEPOSIT_RANK
""", @gcs_prefix, v_prev_month_key, v_prev_month_key);

-- Export 3: AML Screening Results (one file per pattern)
EXECUTE IMMEDIATE FORMAT("""
EXPORT DATA OPTIONS (uri = '%s/aml_structuring_%s_*.csv', format = 'CSV',
                     overwrite = TRUE, header = TRUE, field_delimiter = '|') AS
SELECT * FROM banking_dw.tvf_aml_structuring(CURRENT_DATE(), 30, 50000)
ORDER BY TOTAL_AMOUNT DESC
""", @gcs_prefix, FORMAT_DATE('%Y%m%d', CURRENT_DATE()));

EXECUTE IMMEDIATE FORMAT("""
EXPORT DATA OPTIONS (uri = '%s/aml_rapid_movement_%s_*.csv', format = 'CSV',
                     overwrite = TRUE, header = TRUE, field_delimiter = '|') AS
SELECT * FROM banking_dw.tvf_aml_rapid_movement(CURRENT_DATE(), 30, 50000)
ORDER BY CREDIT_AMOUNT DESC
""", @gcs_prefix, FORMAT_DATE('%Y%m%d', CURRENT_DATE()));

EXECUTE IMMEDIATE FORMAT("""
EXPORT DATA OPTIONS (uri = '%s/aml_new_customer_intl_%s_*.csv', format = 'CSV',
                     overwrite = TRUE, header = TRUE, field_delimiter = '|') AS
SELECT * FROM banking_dw.tvf_aml_new_customer_intl(CURRENT_DATE(), 30, 50000)
ORDER BY TOTAL_INTL_AMOUNT DESC
""", @gcs_prefix, FORMAT_DATE('%Y%m%d', CURRENT_DATE()));

INSERT INTO banking_dw.etl_log (PROCEDURE_NAME, BATCH_ID, LOG_LEVEL, LOG_MESSAGE, LOG_TS)
VALUES ('MONTHLY_EXTRACT', NULL, 'INFO',
        CONCAT('Monthly reports exported successfully at ',
               FORMAT_TIMESTAMP('%Y-%m-%d %H:%M:%S', CURRENT_TIMESTAMP())),
        CURRENT_TIMESTAMP());
