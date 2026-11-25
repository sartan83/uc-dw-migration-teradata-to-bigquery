-- Source: dml/macros/macro_daily_balance_check.sql (Teradata MACRO DAILY_BALANCE_CHECK)
-- Two result sets -> two table functions.
--   QUALIFY ROW_NUMBER() ... = 1 combined with GROUP BY (Teradata evaluates the
--   QUALIFY after grouping, which is ambiguous here) -> the intent, "latest
--   transaction per account on check_date, then aggregate", is made explicit:
--   QUALIFY in a CTE, GROUP BY outside.
--   (FORMAT ...) -> removed; ORDER BY -> caller.
-- Example: SELECT * FROM banking_dw.tvf_daily_balance_summary(CURRENT_DATE())
--          ORDER BY ACCOUNT_TYPE, CURRENCY_CODE;
CREATE OR REPLACE TABLE FUNCTION banking_dw.tvf_daily_balance_summary(check_date DATE)
AS (
    WITH latest AS (
        SELECT a.ACCOUNT_TYPE, a.CURRENCY_CODE, ft.RUNNING_BALANCE
        FROM banking_dw.dim_account a
        INNER JOIN banking_dw.fact_transaction ft ON a.ACCOUNT_KEY = ft.ACCOUNT_KEY
        WHERE a.ACCOUNT_STATUS = 'ACTIVE'
          AND ft.TRANSACTION_DATE = check_date
        QUALIFY ROW_NUMBER() OVER (PARTITION BY ft.ACCOUNT_KEY
                                   ORDER BY ft.TRANSACTION_TS DESC) = 1
    )
    SELECT
        'BALANCE_SUMMARY' AS CHECK_TYPE,
        ACCOUNT_TYPE,
        CURRENCY_CODE,
        COUNT(*) AS ACCOUNT_COUNT,
        SUM(RUNNING_BALANCE) AS TOTAL_BALANCE,
        AVG(RUNNING_BALANCE) AS AVG_BALANCE,
        MIN(RUNNING_BALANCE) AS MIN_BALANCE,
        MAX(RUNNING_BALANCE) AS MAX_BALANCE
    FROM latest
    GROUP BY ACCOUNT_TYPE, CURRENCY_CODE
);

-- Example: SELECT * FROM banking_dw.tvf_negative_balance_alert(CURRENT_DATE())
--          ORDER BY CURRENT_BALANCE ASC;
CREATE OR REPLACE TABLE FUNCTION banking_dw.tvf_negative_balance_alert(check_date DATE)
AS (
    SELECT
        'NEGATIVE_BALANCE_ALERT' AS CHECK_TYPE,
        a.ACCOUNT_ID,
        CONCAT(c.FIRST_NAME, ' ', c.LAST_NAME) AS CUSTOMER_NAME,
        a.ACCOUNT_TYPE,
        ft.RUNNING_BALANCE AS CURRENT_BALANCE,
        a.OVERDRAFT_LIMIT,
        ft.RUNNING_BALANCE - a.OVERDRAFT_LIMIT AS OVER_LIMIT_AMOUNT
    FROM banking_dw.dim_account a
    INNER JOIN banking_dw.dim_customer c ON a.CUSTOMER_ID = c.CUSTOMER_ID
    INNER JOIN banking_dw.fact_transaction ft ON a.ACCOUNT_KEY = ft.ACCOUNT_KEY
    WHERE a.ACCOUNT_TYPE NOT IN ('CREDIT_CARD', 'LOAN')
      AND ft.TRANSACTION_DATE = check_date
      AND ft.RUNNING_BALANCE < 0
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ft.ACCOUNT_KEY
                               ORDER BY ft.TRANSACTION_TS DESC) = 1
);
