-- Source: ddl/tables/04_dim_branch.sql (Teradata SET TABLE BANKING_DW.DIM_BRANCH)
--   SET / table options / COMPRESS / FORMAT / NOT CASESPECIFIC / stats / NUSI -> removed
--   UNIQUE PRIMARY INDEX (BRANCH_ID) -> CLUSTER BY BRANCH_ID + PRIMARY KEY NOT ENFORCED
--   DECIMAL(10,7) lat/long -> NUMERIC(10,7)
CREATE TABLE IF NOT EXISTS banking_dw.dim_branch (
    BRANCH_ID           INT64     NOT NULL,
    BRANCH_CODE         STRING    NOT NULL,
    BRANCH_NAME         STRING    NOT NULL,
    BRANCH_TYPE         STRING,
    ADDRESS_LINE_1      STRING,
    CITY                STRING,
    COUNTY              STRING,
    REGION              STRING,
    POSTAL_CODE         STRING,
    COUNTRY_CODE        STRING    DEFAULT 'NOR',
    LATITUDE            NUMERIC(10, 7),
    LONGITUDE           NUMERIC(10, 7),
    MANAGER_ID          INT64,
    OPENING_DATE        DATE,
    CLOSING_DATE        DATE,
    IS_ACTIVE           INT64     DEFAULT 1,
    EMPLOYEE_COUNT      INT64,
    ETL_BATCH_ID        INT64,
    ETL_INSERT_TS       TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (BRANCH_ID) NOT ENFORCED
)
CLUSTER BY BRANCH_ID, REGION
OPTIONS (description = 'Branch dimension with Norwegian regional hierarchy');
