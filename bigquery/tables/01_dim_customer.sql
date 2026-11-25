-- Source: ddl/tables/01_dim_customer.sql (Teradata SET TABLE BANKING_DW.DIM_CUSTOMER)
--   SET TABLE / NO FALLBACK / JOURNAL / CHECKSUM / MERGEBLOCKRATIO -> removed
--   COMPRESS, FORMAT, NOT CASESPECIFIC, COLLECT STATISTICS, secondary INDEX -> removed
--   UNIQUE PRIMARY INDEX (CUSTOMER_KEY)   -> CLUSTER BY CUSTOMER_KEY (+ NUPI CUSTOMER_ID)
--   PPI RANGE_N(ONBOARDING_DATE ... EACH INTERVAL '1' YEAR)
--                                         -> PARTITION BY DATE_TRUNC(ONBOARDING_DATE, YEAR)
--   GENERATED ALWAYS AS IDENTITY          -> plain INT64; assigned by sp_customer_scd2
--   SET-table row uniqueness              -> enforced by the SCD2 MERGE (one current row
--                                            per CUSTOMER_ID); PK declared NOT ENFORCED
-- The SCD2 history lives in dim_customer_history; analytics read the current-row
-- view dim_customer (bigquery/tables/08_current_dimension_views.sql).
CREATE TABLE IF NOT EXISTS banking_dw.dim_customer_history (
    CUSTOMER_ID         INT64     NOT NULL,
    CUSTOMER_KEY        INT64     NOT NULL,
    FIRST_NAME          STRING    NOT NULL,
    LAST_NAME           STRING    NOT NULL,
    DATE_OF_BIRTH       DATE,
    GENDER              STRING,
    MARITAL_STATUS      STRING,
    EMAIL_ADDRESS       STRING,
    PHONE_NUMBER        STRING,
    ADDRESS_LINE_1      STRING,
    ADDRESS_LINE_2      STRING,
    CITY                STRING,
    STATE_PROVINCE      STRING,
    POSTAL_CODE         STRING,
    COUNTRY_CODE        STRING    DEFAULT 'NOR',
    CUSTOMER_SEGMENT    STRING,
    RISK_SCORE          NUMERIC(5, 2),
    CREDIT_RATING       STRING,
    KYC_STATUS          STRING    DEFAULT 'PENDING' OPTIONS (description = 'Know Your Customer verification status'),
    ONBOARDING_DATE     DATE      NOT NULL,
    LAST_REVIEW_DATE    DATE,
    IS_ACTIVE           INT64     DEFAULT 1,
    EFFECTIVE_FROM      TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    EFFECTIVE_TO        TIMESTAMP DEFAULT TIMESTAMP '9999-12-31 23:59:59+00',
    CURRENT_FLAG        STRING    DEFAULT 'Y',
    ETL_BATCH_ID        INT64,
    ETL_INSERT_TS       TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    ETL_UPDATE_TS       TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (CUSTOMER_KEY) NOT ENFORCED
)
PARTITION BY DATE_TRUNC(ONBOARDING_DATE, YEAR)
CLUSTER BY CUSTOMER_KEY, CUSTOMER_ID, CURRENT_FLAG
OPTIONS (description = 'SCD Type 2 customer dimension with KYC and risk attributes');
