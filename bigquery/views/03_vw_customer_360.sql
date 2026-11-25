-- Source: ddl/views/01_vw_customer_360.sql (Teradata VW_CUSTOMER_360)
--   LOCKING ROW FOR ACCESS / SEL / (FORMAT ...) -> removed / SELECT / removed
--   ZEROIFNULL(x)                 -> IFNULL(x, 0)
--   correlated QUALIFY subquery   -> latest-snapshot CTE with QUALIFY
--   CURRENT_DATE - 90             -> DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
--   (CURRENT_DATE - d) / 365.25   -> DATE_DIFF(CURRENT_DATE(), d, DAY) / 365.25
--   MAX(CHANNEL) "primary"        -> kept as-is (source simplification)
-- Adds deterministic lifetime aggregates (LIFETIME_TXN_COUNT/AMOUNT, NOK base
-- currency) used by the parity contract; the 90-day columns are CURRENT_DATE-
-- relative and therefore not part of the golden checksums.
CREATE OR REPLACE VIEW vw_customer_360 AS
WITH latest_snapshot AS (
    SELECT ACCOUNT_ID, CLOSING_BALANCE
    FROM fact_monthly_account_snapshot
    WHERE TRUE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ACCOUNT_ID
                               ORDER BY SNAPSHOT_DATE DESC) = 1
),
acct_summary AS (
    SELECT
        a.CUSTOMER_ID,
        COUNT(*)                                                      AS TOTAL_ACCOUNTS,
        SUM(CASE WHEN a.ACCOUNT_STATUS = 'ACTIVE' THEN 1 ELSE 0 END)  AS ACTIVE_ACCOUNTS,
        SUM(IFNULL(ls.CLOSING_BALANCE, 0))                            AS TOTAL_BALANCE
    FROM dim_account a
    LEFT JOIN latest_snapshot ls
        ON ls.ACCOUNT_ID = a.ACCOUNT_ID
    GROUP BY a.CUSTOMER_ID
),
txn_summary AS (
    SELECT
        ft.CUSTOMER_ID,
        COUNT(*)                                                      AS LIFETIME_TXN_COUNT,
        SUM(ABS(ft.BASE_CURRENCY_AMOUNT))                             AS LIFETIME_TXN_AMOUNT,
        SUM(CASE WHEN ft.TRANSACTION_DATE >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
                 THEN 1 ELSE 0 END)                                   AS TXN_COUNT_90D,
        SUM(CASE WHEN ft.TRANSACTION_DATE >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
                 THEN ABS(ft.TRANSACTION_AMOUNT) ELSE 0 END)          AS TXN_AMOUNT_90D,
        MAX(ft.TRANSACTION_DATE)                                      AS LAST_TXN_DATE,
        MAX(ft.CHANNEL)                                               AS PRIMARY_CHANNEL
    FROM fact_transaction ft
    GROUP BY ft.CUSTOMER_ID
)
SELECT
    c.CUSTOMER_ID,
    CONCAT(c.FIRST_NAME, ' ', c.LAST_NAME)                            AS FULL_NAME,
    c.CUSTOMER_SEGMENT,
    c.RISK_SCORE,
    c.CREDIT_RATING,
    c.KYC_STATUS,
    c.ONBOARDING_DATE,
    ROUND(DATE_DIFF(CURRENT_DATE(), c.ONBOARDING_DATE, DAY) / 365.25, 1) AS TENURE_YEARS,
    IFNULL(acct.TOTAL_ACCOUNTS, 0)                                    AS total_accounts,
    IFNULL(acct.ACTIVE_ACCOUNTS, 0)                                   AS ACTIVE_ACCOUNTS,
    IFNULL(acct.TOTAL_BALANCE, 0)                                     AS TOTAL_BALANCE,
    IFNULL(txn.LIFETIME_TXN_COUNT, 0)                                 AS LIFETIME_TXN_COUNT,
    IFNULL(txn.LIFETIME_TXN_AMOUNT, 0)                                AS lifetime_txn_amount,
    IFNULL(txn.TXN_COUNT_90D, 0)                                      AS TXN_COUNT_LAST_90_DAYS,
    IFNULL(txn.TXN_AMOUNT_90D, 0)                                     AS TXN_AMOUNT_LAST_90_DAYS,
    txn.LAST_TXN_DATE,
    txn.PRIMARY_CHANNEL,
    c.CITY,
    c.COUNTRY_CODE
FROM dim_customer c
LEFT JOIN acct_summary acct
    ON c.CUSTOMER_ID = acct.CUSTOMER_ID
LEFT JOIN txn_summary txn
    ON c.CUSTOMER_ID = txn.CUSTOMER_ID
WHERE c.IS_ACTIVE = 1;
