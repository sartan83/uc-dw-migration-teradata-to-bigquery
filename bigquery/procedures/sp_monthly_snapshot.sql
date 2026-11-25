-- Source: dml/stored_procedures/sp_monthly_snapshot.sql
-- Teradata -> BigQuery:
--   CAST(TRIM(y (FORMAT '9999')) || ... AS DATE) -> DATE(p_year, p_month, 1)
--   ADD_MONTHS(d, n)                            -> DATE_ADD(d, INTERVAL n MONTH)
--   CREATE VOLATILE TABLE ... WITH DATA         -> CREATE TEMP TABLE ... AS
--   ZEROIFNULL(x)                               -> IFNULL(x, 0)
--   (expr) (SMALLINT)                           -> CAST(expr AS INT64)
--   v_period_end - v_period_start + 1           -> DATE_DIFF(end, start, DAY) + 1
--   MERGE INTO                                  -> MERGE (same semantics)
--   ACTIVITY_COUNT                              -> @@row_count
--   COLLECT STATISTICS                          -> removed
-- Kept as in the source (flagged in MIGRATION_RUNBOOK.md): v_prev_snapshot_date is
-- the first day of the previous month, while snapshots are stored at month end,
-- so the "prev" join never matches and OPENING_BALANCE is always 0. Fixing it
-- here alone would make the dual-run diverge from Teradata.
CREATE OR REPLACE PROCEDURE banking_dw.sp_monthly_snapshot(
    IN p_snapshot_year INT64,
    IN p_snapshot_month INT64,
    IN p_batch_id INT64,
    OUT p_rows_merged INT64,
    OUT p_return_code INT64
)
BEGIN
    DECLARE v_period_start DATE DEFAULT DATE(p_snapshot_year, p_snapshot_month, 1);
    DECLARE v_period_end DATE DEFAULT DATE_SUB(DATE_ADD(v_period_start, INTERVAL 1 MONTH), INTERVAL 1 DAY);
    DECLARE v_snapshot_date DATE DEFAULT v_period_end;
    DECLARE v_snapshot_month_key INT64 DEFAULT p_snapshot_year * 100 + p_snapshot_month;
    DECLARE v_prev_snapshot_date DATE DEFAULT DATE_ADD(v_period_start, INTERVAL -1 MONTH);

    SET p_return_code = 0;
    SET p_rows_merged = 0;

    CREATE TEMP TABLE vt_txn_aggregates AS
    SELECT
        ft.ACCOUNT_KEY,
        SUM(CASE WHEN ft.TRANSACTION_TYPE IN ('DEBIT', 'FEE')
                 THEN ABS(ft.TRANSACTION_AMOUNT) ELSE 0 END) AS TOTAL_DEBITS,
        SUM(CASE WHEN ft.TRANSACTION_TYPE IN ('CREDIT', 'INTEREST')
                 THEN ft.TRANSACTION_AMOUNT ELSE 0 END) AS TOTAL_CREDITS,
        SUM(CASE WHEN ft.TRANSACTION_TYPE IN ('DEBIT', 'FEE') THEN 1 ELSE 0 END) AS DEBIT_COUNT,
        SUM(CASE WHEN ft.TRANSACTION_TYPE IN ('CREDIT', 'INTEREST') THEN 1 ELSE 0 END) AS CREDIT_COUNT,
        SUM(CASE WHEN ft.TRANSACTION_TYPE = 'INTEREST' AND ft.TRANSACTION_AMOUNT > 0
                 THEN ft.TRANSACTION_AMOUNT ELSE 0 END) AS INTEREST_EARNED,
        SUM(CASE WHEN ft.TRANSACTION_TYPE = 'INTEREST' AND ft.TRANSACTION_AMOUNT < 0
                 THEN ABS(ft.TRANSACTION_AMOUNT) ELSE 0 END) AS INTEREST_CHARGED,
        SUM(CASE WHEN ft.TRANSACTION_TYPE = 'FEE'
                 THEN ABS(ft.TRANSACTION_AMOUNT) ELSE 0 END) AS FEES_CHARGED,
        MIN(ft.RUNNING_BALANCE) AS MIN_BALANCE,
        MAX(ft.RUNNING_BALANCE) AS MAX_BALANCE,
        AVG(ft.RUNNING_BALANCE) AS AVG_BALANCE,
        SUM(CASE WHEN ft.RUNNING_BALANCE < 0 THEN 1 ELSE 0 END) AS OVERDRAFT_DAYS
    FROM banking_dw.fact_transaction ft
    WHERE ft.TRANSACTION_DATE BETWEEN v_period_start AND v_period_end
    GROUP BY ft.ACCOUNT_KEY;

    MERGE banking_dw.fact_monthly_account_snapshot tgt
    USING (
        SELECT
            v_snapshot_date AS SNAPSHOT_DATE,
            v_snapshot_month_key AS SNAPSHOT_MONTH_KEY,
            a.ACCOUNT_KEY,
            c.CUSTOMER_KEY,
            a.ACCOUNT_ID,
            a.CUSTOMER_ID,
            a.PRODUCT_ID,
            a.BRANCH_ID,
            IFNULL(prev.CLOSING_BALANCE, 0) AS OPENING_BALANCE,
            IFNULL(prev.CLOSING_BALANCE, 0)
                + IFNULL(agg.TOTAL_CREDITS, 0)
                - IFNULL(agg.TOTAL_DEBITS, 0) AS CLOSING_BALANCE,
            CAST(IFNULL(agg.AVG_BALANCE, 0) AS NUMERIC) AS AVERAGE_BALANCE,
            IFNULL(agg.MIN_BALANCE, 0) AS MINIMUM_BALANCE,
            IFNULL(agg.MAX_BALANCE, 0) AS MAXIMUM_BALANCE,
            IFNULL(agg.TOTAL_DEBITS, 0) AS TOTAL_DEBITS,
            IFNULL(agg.TOTAL_CREDITS, 0) AS TOTAL_CREDITS,
            IFNULL(agg.DEBIT_COUNT, 0) AS DEBIT_COUNT,
            IFNULL(agg.CREDIT_COUNT, 0) AS CREDIT_COUNT,
            IFNULL(agg.INTEREST_EARNED, 0) AS INTEREST_EARNED,
            IFNULL(agg.INTEREST_CHARGED, 0) AS INTEREST_CHARGED,
            IFNULL(agg.FEES_CHARGED, 0) AS FEES_CHARGED,
            IFNULL(agg.OVERDRAFT_DAYS, 0) AS DAYS_IN_OVERDRAFT,
            CASE WHEN agg.ACCOUNT_KEY IS NULL
                 THEN DATE_DIFF(v_period_end, v_period_start, DAY) + 1
                 ELSE 0
            END AS DAYS_DORMANT,
            a.CURRENCY_CODE,
            p_batch_id AS ETL_BATCH_ID
        FROM banking_dw.dim_account a
        -- Teradata LEFT JOINs DIM_CUSTOMER here but never reads it, while the
        -- target CUSTOMER_KEY is NOT NULL; the BigQuery version takes it from
        -- the current customer row (the Teradata source wrote a.CUSTOMER_KEY,
        -- a column DIM_ACCOUNT does not have).
        LEFT JOIN banking_dw.dim_customer c
            ON a.CUSTOMER_ID = c.CUSTOMER_ID
        LEFT JOIN vt_txn_aggregates agg
            ON a.ACCOUNT_KEY = agg.ACCOUNT_KEY
        LEFT JOIN banking_dw.fact_monthly_account_snapshot prev
            ON a.ACCOUNT_KEY = prev.ACCOUNT_KEY
           AND prev.SNAPSHOT_DATE = v_prev_snapshot_date
        WHERE a.ACCOUNT_STATUS IN ('ACTIVE', 'DORMANT')
    ) src
    ON tgt.ACCOUNT_KEY = src.ACCOUNT_KEY
       AND tgt.SNAPSHOT_MONTH_KEY = src.SNAPSHOT_MONTH_KEY
    WHEN MATCHED THEN UPDATE SET
        OPENING_BALANCE   = src.OPENING_BALANCE,
        CLOSING_BALANCE   = src.CLOSING_BALANCE,
        AVERAGE_BALANCE   = src.AVERAGE_BALANCE,
        MINIMUM_BALANCE   = src.MINIMUM_BALANCE,
        MAXIMUM_BALANCE   = src.MAXIMUM_BALANCE,
        TOTAL_DEBITS      = src.TOTAL_DEBITS,
        TOTAL_CREDITS     = src.TOTAL_CREDITS,
        DEBIT_COUNT       = src.DEBIT_COUNT,
        CREDIT_COUNT      = src.CREDIT_COUNT,
        INTEREST_EARNED   = src.INTEREST_EARNED,
        INTEREST_CHARGED  = src.INTEREST_CHARGED,
        FEES_CHARGED      = src.FEES_CHARGED,
        DAYS_IN_OVERDRAFT = src.DAYS_IN_OVERDRAFT,
        DAYS_DORMANT      = src.DAYS_DORMANT,
        ETL_BATCH_ID      = src.ETL_BATCH_ID,
        ETL_INSERT_TS     = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
        SNAPSHOT_DATE, SNAPSHOT_MONTH_KEY, ACCOUNT_KEY, CUSTOMER_KEY,
        ACCOUNT_ID, CUSTOMER_ID,
        PRODUCT_ID, BRANCH_ID, OPENING_BALANCE, CLOSING_BALANCE,
        AVERAGE_BALANCE, MINIMUM_BALANCE, MAXIMUM_BALANCE,
        TOTAL_DEBITS, TOTAL_CREDITS, DEBIT_COUNT, CREDIT_COUNT,
        INTEREST_EARNED, INTEREST_CHARGED, FEES_CHARGED,
        DAYS_IN_OVERDRAFT, DAYS_DORMANT, CURRENCY_CODE,
        ETL_BATCH_ID, ETL_INSERT_TS
    ) VALUES (
        src.SNAPSHOT_DATE, src.SNAPSHOT_MONTH_KEY, src.ACCOUNT_KEY, src.CUSTOMER_KEY,
        src.ACCOUNT_ID, src.CUSTOMER_ID,
        src.PRODUCT_ID, src.BRANCH_ID, src.OPENING_BALANCE, src.CLOSING_BALANCE,
        src.AVERAGE_BALANCE, src.MINIMUM_BALANCE, src.MAXIMUM_BALANCE,
        src.TOTAL_DEBITS, src.TOTAL_CREDITS, src.DEBIT_COUNT, src.CREDIT_COUNT,
        src.INTEREST_EARNED, src.INTEREST_CHARGED, src.FEES_CHARGED,
        src.DAYS_IN_OVERDRAFT, src.DAYS_DORMANT, src.CURRENCY_CODE,
        src.ETL_BATCH_ID, CURRENT_TIMESTAMP()
    );

    SET p_rows_merged = @@row_count;

    DROP TABLE vt_txn_aggregates;
END;
