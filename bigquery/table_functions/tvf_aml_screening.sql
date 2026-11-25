-- Source: dml/macros/macro_aml_screening.sql (Teradata MACRO AML_SCREENING)
-- A Teradata macro returning three result sets -> three BigQuery table functions,
-- one per pattern (a TVF returns exactly one table). Callers run all three.
--   :param                        -> TVF parameter
--   DEFAULT DATE / 30 / 50000.00  -> no TVF defaults; callers pass
--                                    (CURRENT_DATE(), 30, 50000) explicitly
--   :d - :n (date arithmetic)     -> DATE_SUB(d, INTERVAL n DAY)
--   (FORMAT ...)                  -> removed
--   ORDER BY inside the macro     -> moved to the caller (TVF output is unordered)
--   d2 - d1 (days between)        -> DATE_DIFF(d2, d1, DAY)
-- Example:
--   SELECT * FROM banking_dw.tvf_aml_structuring(CURRENT_DATE(), 30, 50000)
--   ORDER BY TOTAL_AMOUNT DESC;
CREATE OR REPLACE TABLE FUNCTION banking_dw.tvf_aml_structuring(
    screening_date DATE, lookback_days INT64, amount_threshold NUMERIC)
AS (
    SELECT
        'STRUCTURING' AS PATTERN_TYPE,
        c.CUSTOMER_ID,
        CONCAT(c.FIRST_NAME, ' ', c.LAST_NAME) AS CUSTOMER_NAME,
        c.KYC_STATUS,
        a.ACCOUNT_ID,
        COUNT(*) AS TXN_COUNT,
        SUM(ft.BASE_CURRENCY_AMOUNT) AS TOTAL_AMOUNT,
        AVG(ft.BASE_CURRENCY_AMOUNT) AS AVG_AMOUNT,
        MAX(ft.TRANSACTION_DATE) AS LAST_TXN_DATE
    FROM banking_dw.fact_transaction ft
    INNER JOIN banking_dw.dim_account a ON ft.ACCOUNT_KEY = a.ACCOUNT_KEY
    INNER JOIN banking_dw.dim_customer c ON ft.CUSTOMER_KEY = c.CUSTOMER_KEY
    WHERE ft.TRANSACTION_DATE BETWEEN DATE_SUB(screening_date, INTERVAL lookback_days DAY)
                                  AND screening_date
      AND ft.TRANSACTION_TYPE IN ('CREDIT', 'DEBIT')
      AND ft.BASE_CURRENCY_AMOUNT BETWEEN amount_threshold * 0.8 AND amount_threshold
    GROUP BY c.CUSTOMER_ID, c.FIRST_NAME, c.LAST_NAME, c.KYC_STATUS, a.ACCOUNT_ID
    HAVING COUNT(*) >= 3
);

-- Example: ... FROM banking_dw.tvf_aml_rapid_movement(CURRENT_DATE(), 30, 50000)
--          ORDER BY CREDIT_AMOUNT DESC;
CREATE OR REPLACE TABLE FUNCTION banking_dw.tvf_aml_rapid_movement(
    screening_date DATE, lookback_days INT64, amount_threshold NUMERIC)
AS (
    SELECT
        'RAPID_MOVEMENT' AS PATTERN_TYPE,
        c.CUSTOMER_ID,
        CONCAT(c.FIRST_NAME, ' ', c.LAST_NAME) AS CUSTOMER_NAME,
        a.ACCOUNT_ID,
        cr.CREDIT_DATE,
        cr.CREDIT_AMOUNT,
        dr.DEBIT_DATE,
        dr.DEBIT_AMOUNT,
        DATE_DIFF(dr.DEBIT_DATE, cr.CREDIT_DATE, DAY) AS DAYS_BETWEEN
    FROM banking_dw.dim_customer c
    INNER JOIN banking_dw.dim_account a ON c.CUSTOMER_ID = a.CUSTOMER_ID
    INNER JOIN (
        SELECT ACCOUNT_KEY, TRANSACTION_DATE AS CREDIT_DATE,
               BASE_CURRENCY_AMOUNT AS CREDIT_AMOUNT
        FROM banking_dw.fact_transaction
        WHERE TRANSACTION_TYPE = 'CREDIT'
          AND BASE_CURRENCY_AMOUNT >= amount_threshold
          AND TRANSACTION_DATE BETWEEN DATE_SUB(screening_date, INTERVAL lookback_days DAY)
                                   AND screening_date
    ) cr ON a.ACCOUNT_KEY = cr.ACCOUNT_KEY
    INNER JOIN (
        SELECT ACCOUNT_KEY, TRANSACTION_DATE AS DEBIT_DATE,
               BASE_CURRENCY_AMOUNT AS DEBIT_AMOUNT
        FROM banking_dw.fact_transaction
        WHERE TRANSACTION_TYPE IN ('DEBIT', 'TRANSFER')
          AND BASE_CURRENCY_AMOUNT >= amount_threshold * 0.9
          AND TRANSACTION_DATE BETWEEN DATE_SUB(screening_date, INTERVAL lookback_days DAY)
                                   AND screening_date
    ) dr ON cr.ACCOUNT_KEY = dr.ACCOUNT_KEY
        AND dr.DEBIT_DATE BETWEEN cr.CREDIT_DATE AND DATE_ADD(cr.CREDIT_DATE, INTERVAL 3 DAY)
);

-- Example: ... FROM banking_dw.tvf_aml_new_customer_intl(CURRENT_DATE(), 30, 50000)
--          ORDER BY TOTAL_INTL_AMOUNT DESC;
CREATE OR REPLACE TABLE FUNCTION banking_dw.tvf_aml_new_customer_intl(
    screening_date DATE, lookback_days INT64, amount_threshold NUMERIC)
AS (
    SELECT
        'NEW_CUSTOMER_INTL' AS PATTERN_TYPE,
        c.CUSTOMER_ID,
        CONCAT(c.FIRST_NAME, ' ', c.LAST_NAME) AS CUSTOMER_NAME,
        c.ONBOARDING_DATE,
        DATE_DIFF(screening_date, c.ONBOARDING_DATE, DAY) AS DAYS_SINCE_ONBOARD,
        c.KYC_STATUS,
        COUNT(*) AS INTL_TXN_COUNT,
        SUM(ft.BASE_CURRENCY_AMOUNT) AS TOTAL_INTL_AMOUNT
    FROM banking_dw.fact_transaction ft
    INNER JOIN banking_dw.dim_customer c ON ft.CUSTOMER_KEY = c.CUSTOMER_KEY
    WHERE ft.IS_INTERNATIONAL = 1
      AND ft.TRANSACTION_DATE BETWEEN DATE_SUB(screening_date, INTERVAL lookback_days DAY)
                                  AND screening_date
      AND c.ONBOARDING_DATE >= DATE_SUB(screening_date, INTERVAL 90 DAY)
    GROUP BY c.CUSTOMER_ID, c.FIRST_NAME, c.LAST_NAME, c.ONBOARDING_DATE, c.KYC_STATUS
    HAVING SUM(ft.BASE_CURRENCY_AMOUNT) >= amount_threshold
);
