-- Source: ddl/tables/06_fact_transaction.sql (Teradata MULTISET TABLE BANKING_DW.FACT_TRANSACTION)
--   MULTISET / table options / COMPRESS / FORMAT / NOT CASESPECIFIC / stats -> removed
--   PRIMARY INDEX (ACCOUNT_KEY, TRANSACTION_DATE) -> CLUSTER BY ACCOUNT_KEY, TRANSACTION_DATE
--   PPI RANGE_N(TRANSACTION_DATE ... EACH INTERVAL '1' MONTH, NO RANGE)
--                                     -> PARTITION BY DATE_TRUNC(TRANSACTION_DATE, MONTH)
--                                        (out-of-range dates land in __UNPARTITIONED__/
--                                         __NULL__, the NO RANGE equivalent)
--   TIME(0) -> TIME; TIMESTAMP(6)/(0) -> TIMESTAMP; DECIMAL -> NUMERIC; BYTEINT -> INT64
-- Added: ACCOUNT_ID / CUSTOMER_ID natural keys, denormalised at load by
-- sp_load_daily_transactions, so analytic views join on natural keys without
-- resolving SCD2 surrogate keys (BigQuery favours denormalised facts).
CREATE TABLE IF NOT EXISTS banking_dw.fact_transaction (
    TRANSACTION_ID       INT64     NOT NULL,
    TRANSACTION_DATE     DATE      NOT NULL,
    TRANSACTION_TIME     TIME,
    TRANSACTION_TS       TIMESTAMP,
    ACCOUNT_KEY          INT64     NOT NULL,
    CUSTOMER_KEY         INT64     NOT NULL,
    ACCOUNT_ID           STRING    NOT NULL,
    CUSTOMER_ID          INT64     NOT NULL,
    PRODUCT_ID           INT64     NOT NULL,
    BRANCH_ID            INT64,
    DATE_KEY             INT64     NOT NULL,
    TRANSACTION_TYPE     STRING    NOT NULL,
    TRANSACTION_SUBTYPE  STRING,
    CHANNEL              STRING,
    TRANSACTION_AMOUNT   NUMERIC(15, 2) NOT NULL,
    TRANSACTION_CURRENCY STRING    DEFAULT 'NOK',
    BASE_CURRENCY_AMOUNT NUMERIC(15, 2),
    EXCHANGE_RATE        NUMERIC(12, 6) DEFAULT 1.000000,
    RUNNING_BALANCE      NUMERIC(15, 2),
    MERCHANT_ID          STRING,
    MERCHANT_NAME        STRING,
    MERCHANT_CATEGORY    STRING    OPTIONS (description = 'MCC code'),
    COUNTERPARTY_ACCT    STRING,
    REFERENCE_NUMBER     STRING,
    DESCRIPTION_TEXT     STRING,
    IS_INTERNATIONAL     INT64     DEFAULT 0,
    IS_FLAGGED           INT64     DEFAULT 0,
    FLAG_REASON          STRING,
    POSTING_DATE         DATE,
    VALUE_DATE           DATE,
    ETL_BATCH_ID         INT64,
    ETL_INSERT_TS        TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
)
PARTITION BY DATE_TRUNC(TRANSACTION_DATE, MONTH)
CLUSTER BY ACCOUNT_KEY, TRANSACTION_DATE, ACCOUNT_ID, CUSTOMER_ID
OPTIONS (
    description = 'Grain: one row per transaction. Monthly partitions replace the Teradata PPI on TRANSACTION_DATE.',
    require_partition_filter = FALSE
);
