-- Source: ddl/views/03_vw_branch_performance.sql (Teradata VW_BRANCH_PERFORMANCE)
--   CSUM(SUM(fees), month)        -> SUM(...) OVER (PARTITION BY branch ORDER BY month
--                                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
--   MAVG(SUM(volume), 3, month)   -> AVG(...) OVER (PARTITION BY branch ORDER BY month
--                                    ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
--                                    (3 rows = current + 2 preceding; NOT "3 PRECEDING")
--   Teradata resets CSUM/MAVG per GROUP BY group, hence PARTITION BY BRANCH_ID.
--   NULLIFZERO(x)                 -> SAFE_DIVIDE (NULL on zero denominator)
--   (FORMAT '...')                -> removed; format at the presentation layer
--   MONTH_LABEL                   -> derived from SNAPSHOT_MONTH_KEY (no DIM_DATE join)
--   ADD_MONTHS(CURRENT_DATE,-24)  -> not applied here; the 24-month window is a
--                                    consumer filter (see bigquery/README.md) so the
--                                    view is deterministic and partition-prunable.
CREATE OR REPLACE VIEW vw_branch_monthly_performance AS
WITH branch_month AS (
    SELECT
        b.BRANCH_ID,
        b.BRANCH_NAME,
        b.BRANCH_TYPE,
        b.REGION,
        b.CITY,
        snap.SNAPSHOT_MONTH_KEY,
        COUNT(DISTINCT snap.ACCOUNT_ID)                 AS ACCOUNTS_SERVICED,
        COUNT(DISTINCT snap.CUSTOMER_ID)                AS CUSTOMERS_SERVICED,
        SUM(snap.CLOSING_BALANCE)                       AS TOTAL_DEPOSITS,
        SUM(snap.TOTAL_DEBITS + snap.TOTAL_CREDITS)     AS TOTAL_VOLUME,
        SUM(snap.FEES_CHARGED)                          AS TOTAL_FEES_EARNED,
        SUM(snap.INTEREST_CHARGED)                      AS TOTAL_INTEREST_INCOME,
        AVG(snap.CLOSING_BALANCE)                       AS AVG_ACCOUNT_BALANCE
    FROM fact_monthly_account_snapshot snap
    INNER JOIN dim_branch b
        ON snap.BRANCH_ID = b.BRANCH_ID
    WHERE b.IS_ACTIVE = 1
    GROUP BY b.BRANCH_ID, b.BRANCH_NAME, b.BRANCH_TYPE, b.REGION, b.CITY,
             snap.SNAPSHOT_MONTH_KEY
),
windowed AS (
    SELECT
        bm.*,
        CONCAT(SUBSTR(CAST(bm.SNAPSHOT_MONTH_KEY AS STRING), 1, 4), '-',
               SUBSTR(CAST(bm.SNAPSHOT_MONTH_KEY AS STRING), 5, 2)) AS MONTH_LABEL,
        SUM(bm.TOTAL_FEES_EARNED) OVER (
            PARTITION BY bm.BRANCH_ID
            ORDER BY bm.SNAPSHOT_MONTH_KEY
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)       AS cumulative_fees,
        AVG(bm.TOTAL_VOLUME) OVER (
            PARTITION BY bm.BRANCH_ID
            ORDER BY bm.SNAPSHOT_MONTH_KEY
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)               AS moving_avg_volume_3m,
        RANK() OVER (
            PARTITION BY bm.REGION, bm.SNAPSHOT_MONTH_KEY
            ORDER BY bm.TOTAL_DEPOSITS DESC)                        AS REGION_DEPOSIT_RANK,
        SUM(bm.TOTAL_DEPOSITS) OVER (
            PARTITION BY bm.REGION, bm.SNAPSHOT_MONTH_KEY)          AS region_total_deposits
    FROM branch_month bm
)
SELECT
    BRANCH_ID,
    BRANCH_NAME,
    BRANCH_TYPE,
    REGION,
    CITY,
    SNAPSHOT_MONTH_KEY,
    MONTH_LABEL,
    ACCOUNTS_SERVICED,
    CUSTOMERS_SERVICED,
    TOTAL_DEPOSITS,
    TOTAL_VOLUME,
    TOTAL_FEES_EARNED,
    TOTAL_INTEREST_INCOME,
    AVG_ACCOUNT_BALANCE,
    cumulative_fees,
    moving_avg_volume_3m,
    REGION_DEPOSIT_RANK,
    SAFE_DIVIDE(TOTAL_DEPOSITS, region_total_deposits) * 100 AS PCT_OF_REGION_DEPOSITS
FROM windowed;
