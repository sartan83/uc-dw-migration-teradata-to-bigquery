-- Source: dml/stored_procedures/sp_load_daily_transactions.sql
-- Teradata -> BigQuery:
--   DECLARE EXIT HANDLER FOR SQLEXCEPTION -> BEGIN ... EXCEPTION WHEN ERROR THEN ... END
--   SQLCODE                               -> @@error.message (p_return_code = -1)
--   ACTIVITY_COUNT                        -> @@row_count
--   ZEROIFNULL(x)                         -> IFNULL(x, 0)
--   date (TIMESTAMP(6)) + time interval   -> TIMESTAMP(DATETIME(date, time))
--   CAST(date AS DATE FORMAT 'YYYYMMDD')  -> CAST(FORMAT_DATE('%Y%m%d', date) AS INT64)
--   TRIM(n (FORMAT ...)) / CAST AS VARCHAR -> CAST(n AS STRING) / FORMAT()
--   COLLECT STATISTICS                    -> removed
-- Also writes the ACCOUNT_ID / CUSTOMER_ID natural keys onto the fact row.
-- The staging table itself is filled outside SQL (see bigquery/orchestration/README.md).
CREATE OR REPLACE PROCEDURE banking_dw.sp_load_daily_transactions(
    IN p_batch_date DATE,
    IN p_batch_id INT64,
    OUT p_rows_inserted INT64,
    OUT p_rows_rejected INT64,
    OUT p_return_code INT64
)
BEGIN
    DECLARE v_start_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
    DECLARE v_error_count INT64 DEFAULT 0;

    SET p_rows_inserted = 0;
    SET p_rows_rejected = 0;
    SET p_return_code = 0;

    BEGIN
        INSERT INTO banking_dw.etl_log (PROCEDURE_NAME, BATCH_ID, LOG_LEVEL, LOG_MESSAGE, LOG_TS)
        VALUES ('SP_LOAD_DAILY_TRANSACTIONS', p_batch_id, 'INFO',
                CONCAT('Started loading transactions for date: ', CAST(p_batch_date AS STRING)),
                v_start_ts);

        -- Reject bad records to error table
        INSERT INTO banking_dw.stg_transaction_errors
        SELECT stg.*, 'INVALID_ACCOUNT' AS ERROR_REASON, p_batch_id AS BATCH_ID
        FROM banking_dw.stg_transactions stg
        WHERE stg.LOAD_DATE = p_batch_date
          AND stg.ACCOUNT_ID NOT IN (SELECT ACCOUNT_ID FROM banking_dw.dim_account);

        SET v_error_count = @@row_count;

        -- Insert valid transactions
        INSERT INTO banking_dw.fact_transaction (
            TRANSACTION_ID, TRANSACTION_DATE, TRANSACTION_TIME, TRANSACTION_TS,
            ACCOUNT_KEY, CUSTOMER_KEY, ACCOUNT_ID, CUSTOMER_ID,
            PRODUCT_ID, BRANCH_ID, DATE_KEY,
            TRANSACTION_TYPE, TRANSACTION_SUBTYPE, CHANNEL,
            TRANSACTION_AMOUNT, TRANSACTION_CURRENCY, BASE_CURRENCY_AMOUNT,
            EXCHANGE_RATE, MERCHANT_ID, MERCHANT_NAME, MERCHANT_CATEGORY,
            COUNTERPARTY_ACCT, REFERENCE_NUMBER, DESCRIPTION_TEXT,
            IS_INTERNATIONAL, POSTING_DATE, VALUE_DATE,
            ETL_BATCH_ID, ETL_INSERT_TS
        )
        SELECT
            stg.TRANSACTION_ID,
            stg.TRANSACTION_DATE,
            stg.TRANSACTION_TIME,
            TIMESTAMP(DATETIME(stg.TRANSACTION_DATE, IFNULL(stg.TRANSACTION_TIME, TIME '00:00:00'))),
            a.ACCOUNT_KEY,
            c.CUSTOMER_KEY,
            a.ACCOUNT_ID,
            c.CUSTOMER_ID,
            a.PRODUCT_ID,
            a.BRANCH_ID,
            CAST(FORMAT_DATE('%Y%m%d', stg.TRANSACTION_DATE) AS INT64),
            stg.TRANSACTION_TYPE,
            stg.TRANSACTION_SUBTYPE,
            stg.CHANNEL,
            stg.TRANSACTION_AMOUNT,
            stg.CURRENCY_CODE,
            CASE WHEN stg.CURRENCY_CODE <> 'NOK'
                 THEN ROUND(stg.TRANSACTION_AMOUNT * IFNULL(fx.EXCHANGE_RATE, 0), 2)
                 ELSE stg.TRANSACTION_AMOUNT
            END,
            IFNULL(fx.EXCHANGE_RATE, 0),
            stg.MERCHANT_ID,
            stg.MERCHANT_NAME,
            stg.MERCHANT_CATEGORY,
            stg.COUNTERPARTY_ACCT,
            stg.REFERENCE_NUMBER,
            stg.DESCRIPTION_TEXT,
            CASE WHEN stg.CURRENCY_CODE <> 'NOK' THEN 1 ELSE 0 END,
            stg.POSTING_DATE,
            stg.VALUE_DATE,
            p_batch_id,
            CURRENT_TIMESTAMP()
        FROM banking_dw.stg_transactions stg
        INNER JOIN banking_dw.dim_account a
            ON stg.ACCOUNT_ID = a.ACCOUNT_ID
        INNER JOIN banking_dw.dim_customer c
            ON a.CUSTOMER_ID = c.CUSTOMER_ID
        LEFT JOIN banking_dw.dim_exchange_rates fx
            ON stg.CURRENCY_CODE = fx.FROM_CURRENCY
           AND fx.TO_CURRENCY = 'NOK'
           AND stg.TRANSACTION_DATE = fx.RATE_DATE
        WHERE stg.LOAD_DATE = p_batch_date;

        SET p_rows_inserted = @@row_count;
        SET p_rows_rejected = v_error_count;

        INSERT INTO banking_dw.etl_log (PROCEDURE_NAME, BATCH_ID, LOG_LEVEL, LOG_MESSAGE, LOG_TS)
        VALUES ('SP_LOAD_DAILY_TRANSACTIONS', p_batch_id, 'INFO',
                FORMAT('Completed. Inserted: %d, Rejected: %d, Duration: %d s',
                       p_rows_inserted, p_rows_rejected,
                       TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), v_start_ts, SECOND)),
                CURRENT_TIMESTAMP());
    EXCEPTION WHEN ERROR THEN
        SET p_return_code = -1;
        INSERT INTO banking_dw.etl_log (PROCEDURE_NAME, BATCH_ID, LOG_LEVEL, LOG_MESSAGE, LOG_TS)
        VALUES ('SP_LOAD_DAILY_TRANSACTIONS', p_batch_id, 'ERROR',
                CONCAT('ERROR: ', @@error.message, ' at ', CAST(CURRENT_TIMESTAMP() AS STRING)),
                CURRENT_TIMESTAMP());
    END;
END;
