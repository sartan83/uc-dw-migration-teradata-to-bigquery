-- Source: ddl/views/02_vw_regulatory_large_transactions.sql (Teradata)
--   LOCKING ROW FOR ACCESS   -> removed (no read locks in BigQuery)
--   SEL                      -> SELECT
--   (NOT CASESPECIFIC)       -> removed; STRING compare is case-sensitive
--   HASHROW(id, date)        -> FARM_FINGERPRINT(CONCAT(...)) (INT64)
--   QUALIFY ROW_NUMBER() ... -> QUALIFY (native GoogleSQL)
-- Joins use natural keys (ACCOUNT_ID / CUSTOMER_ID); dim_account and
-- dim_customer are the current-row (CURRENT_FLAG = 'Y') views over the SCD2
-- history tables, see bigquery/tables/.
CREATE OR REPLACE VIEW vw_regulatory_large_transactions AS
SELECT
    ft.TRANSACTION_ID,
    ft.TRANSACTION_DATE,
    c.CUSTOMER_ID,
    c.FIRST_NAME,
    c.LAST_NAME,
    c.KYC_STATUS,
    a.ACCOUNT_ID,
    a.ACCOUNT_TYPE,
    ft.TRANSACTION_TYPE,
    ft.CHANNEL,
    ft.TRANSACTION_AMOUNT,
    ft.TRANSACTION_CURRENCY,
    ft.BASE_CURRENCY_AMOUNT,
    ft.MERCHANT_NAME,
    ft.IS_INTERNATIONAL,
    ft.IS_FLAGGED,
    b.BRANCH_NAME,
    b.REGION,
    CASE
        WHEN ft.BASE_CURRENCY_AMOUNT >= 100000 THEN 'THRESHOLD_EXCEEDED'
        WHEN ft.IS_INTERNATIONAL = 1
             AND ft.BASE_CURRENCY_AMOUNT >= 25000 THEN 'INTL_THRESHOLD'
        WHEN ft.IS_FLAGGED = 1 THEN 'FLAGGED_SUSPICIOUS'
        ELSE 'REVIEW'
    END AS REPORTING_CATEGORY,
    FARM_FINGERPRINT(CONCAT(CAST(ft.TRANSACTION_ID AS STRING), '|',
                            CAST(ft.TRANSACTION_DATE AS STRING))) AS ROW_HASH,
    ft.ETL_BATCH_ID
FROM fact_transaction ft
INNER JOIN dim_account a
    ON ft.ACCOUNT_ID = a.ACCOUNT_ID
INNER JOIN dim_customer c
    ON ft.CUSTOMER_ID = c.CUSTOMER_ID
LEFT JOIN dim_branch b
    ON ft.BRANCH_ID = b.BRANCH_ID
WHERE (ft.BASE_CURRENCY_AMOUNT >= 100000
       OR (ft.IS_INTERNATIONAL = 1 AND ft.BASE_CURRENCY_AMOUNT >= 25000)
       OR ft.IS_FLAGGED = 1)
QUALIFY ROW_NUMBER() OVER (PARTITION BY ft.TRANSACTION_ID
                           ORDER BY ft.ETL_BATCH_ID DESC) = 1;
