-- Source: dml/macros/macro_customer_txn_history.sql (Teradata MACRO CUSTOMER_TXN_HISTORY)
--   parameters with DEFAULT        -> TVF parameters; callers pass
--                                     (cust_id, DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY),
--                                      CURRENT_DATE(), 'ALL')
--   (FORMAT ...)                   -> removed
--   SAMPLE 1000                    -> ORDER BY RAND() LIMIT 1000 (random 1000 rows,
--                                     like SAMPLE; non-deterministic in both systems)
--   final ORDER BY                 -> caller:
--     ORDER BY TXN_DATE DESC, TXN_TIME DESC
CREATE OR REPLACE TABLE FUNCTION banking_dw.tvf_customer_txn_history(
    cust_id INT64, start_date DATE, end_date DATE, txn_type STRING)
AS (
    SELECT
        ft.TRANSACTION_DATE AS TXN_DATE,
        ft.TRANSACTION_TIME AS TXN_TIME,
        a.ACCOUNT_ID,
        a.ACCOUNT_TYPE,
        ft.TRANSACTION_TYPE,
        ft.TRANSACTION_SUBTYPE,
        ft.CHANNEL,
        ft.TRANSACTION_AMOUNT AS AMOUNT,
        ft.TRANSACTION_CURRENCY AS CCY,
        ft.RUNNING_BALANCE AS BALANCE,
        COALESCE(ft.MERCHANT_NAME, ft.COUNTERPARTY_ACCT, '--') AS PAYEE,
        ft.DESCRIPTION_TEXT AS DESCRIPTION,
        ft.REFERENCE_NUMBER AS REF_NO
    FROM banking_dw.fact_transaction ft
    INNER JOIN banking_dw.dim_account a ON ft.ACCOUNT_KEY = a.ACCOUNT_KEY
    INNER JOIN banking_dw.dim_customer c ON ft.CUSTOMER_KEY = c.CUSTOMER_KEY
    WHERE c.CUSTOMER_ID = cust_id
      AND ft.TRANSACTION_DATE BETWEEN start_date AND end_date
      AND (ft.TRANSACTION_TYPE = txn_type OR txn_type = 'ALL')
    ORDER BY RAND()
    LIMIT 1000
);
