-- Source: dml/scripts/bteq_daily_load.btq
-- BigQuery multi-statement script, run once per day by the orchestrator
-- (see bigquery/orchestration/README.md). Default dataset: banking_dw.
--   .LOGON / .SET / DATABASE        -> service account + job default dataset
--   .IF ACTIVITYCOUNT = 0 .GOTO     -> IF ... THEN ... RETURN
--   .IF ERRORCODE <> 0 .GOTO        -> BEGIN ... EXCEPTION WHEN ERROR
--   .QUIT 4 (warning) / .QUIT 8     -> warning row in etl_log + RETURN /
--                                      RAISE (job fails, orchestrator alerts)
--   VOLATILE TABLE VT_BATCH         -> script variables
--   CALL with OUT params            -> CALL with DECLAREd variables
--   EXEC DAILY_BALANCE_CHECK        -> SELECT from the two table functions
--   .EXPORT REPORT FILE=...         -> EXPORT DATA to GCS (@gcs_report_uri)
-- Query parameter: @gcs_report_uri, e.g.
--   'gs://<bucket>/reports/daily_recon_20261124_*.csv'
-- Gap kept from the source: rejected rows are not removed from staging.
DECLARE v_batch_date DATE DEFAULT CURRENT_DATE();
DECLARE v_batch_id INT64;
DECLARE v_batch_start_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
DECLARE v_staged_rows INT64;
DECLARE v_new_rows INT64;
DECLARE v_changed_rows INT64;
DECLARE v_rows_inserted INT64;
DECLARE v_rows_rejected INT64;
DECLARE v_return_code INT64;

-- Step 1: Validate staging data
SET v_staged_rows = (SELECT COUNT(*) FROM banking_dw.stg_transactions
                     WHERE LOAD_DATE = v_batch_date);

IF v_staged_rows = 0 THEN
    INSERT INTO banking_dw.etl_log (PROCEDURE_NAME, BATCH_ID, LOG_LEVEL, LOG_MESSAGE, LOG_TS)
    VALUES ('DAILY_LOAD', NULL, 'WARN',
            CONCAT('WARNING: No staging data found for ', CAST(v_batch_date AS STRING)),
            CURRENT_TIMESTAMP());
    RETURN;
END IF;

SELECT 'STAGING_CHECK' AS STEP_NAME,
       COUNT(*) AS ROW_COUNT,
       MIN(LOAD_DATE) AS MIN_DATE,
       MAX(LOAD_DATE) AS MAX_DATE,
       COUNT(DISTINCT ACCOUNT_ID) AS DISTINCT_ACCOUNTS
FROM banking_dw.stg_transactions
WHERE LOAD_DATE = v_batch_date;

-- Step 2: Generate new batch ID
SET v_batch_id = (SELECT IFNULL(MAX(BATCH_ID), 0) + 1 FROM banking_dw.etl_batch_control);

BEGIN
    -- Step 3: SCD2 customer dimension
    CALL banking_dw.sp_customer_scd2(v_batch_id, v_new_rows, v_changed_rows, v_return_code);
    IF v_return_code <> 0 THEN
        RAISE USING MESSAGE = FORMAT('sp_customer_scd2 returned %d', v_return_code);
    END IF;

    -- Step 4: Load daily transactions
    CALL banking_dw.sp_load_daily_transactions(
        v_batch_date, v_batch_id, v_rows_inserted, v_rows_rejected, v_return_code);
    IF v_return_code <> 0 THEN
        RAISE USING MESSAGE = FORMAT('sp_load_daily_transactions returned %d', v_return_code);
    END IF;

    -- Step 5: Balance reconciliation (macro result sets)
    SELECT * FROM banking_dw.tvf_daily_balance_summary(v_batch_date)
    ORDER BY ACCOUNT_TYPE, CURRENCY_CODE;
    SELECT * FROM banking_dw.tvf_negative_balance_alert(v_batch_date)
    ORDER BY CURRENT_BALANCE ASC;

    -- Step 6: Export reconciliation report
    EXPORT DATA OPTIONS (
        uri = @gcs_report_uri,
        format = 'CSV',
        overwrite = TRUE,
        header = TRUE,
        field_delimiter = '|'
    ) AS
    SELECT
        'DAILY_RECONCILIATION' AS REPORT_TYPE,
        v_batch_date AS REPORT_DATE,
        v_batch_id AS BATCH_ID,
        (SELECT COUNT(*) FROM banking_dw.stg_transactions
         WHERE LOAD_DATE = v_batch_date) AS STAGED_ROWS,
        (SELECT COUNT(*) FROM banking_dw.fact_transaction
         WHERE ETL_BATCH_ID = v_batch_id) AS LOADED_ROWS,
        (SELECT COUNT(*) FROM banking_dw.stg_transaction_errors
         WHERE BATCH_ID = v_batch_id) AS ERROR_ROWS;

    -- Step 7: Record batch completion
    INSERT INTO banking_dw.etl_batch_control (BATCH_ID, BATCH_DATE, BATCH_STATUS, START_TS, END_TS)
    VALUES (v_batch_id, v_batch_date, 'COMPLETED', v_batch_start_ts, CURRENT_TIMESTAMP());
EXCEPTION WHEN ERROR THEN
    INSERT INTO banking_dw.etl_batch_control (BATCH_ID, BATCH_DATE, BATCH_STATUS, START_TS, END_TS)
    VALUES (v_batch_id, v_batch_date, 'FAILED', v_batch_start_ts, CURRENT_TIMESTAMP());
    INSERT INTO banking_dw.etl_log (PROCEDURE_NAME, BATCH_ID, LOG_LEVEL, LOG_MESSAGE, LOG_TS)
    VALUES ('DAILY_LOAD', v_batch_id, 'ERROR',
            CONCAT('ERROR: ETL pipeline failed. ', @@error.message), CURRENT_TIMESTAMP());
    RAISE USING MESSAGE = CONCAT('DAILY_LOAD failed: ', @@error.message);
END;
