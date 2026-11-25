-- Source: ddl/tables/05_dim_date.sql (Teradata SET TABLE BANKING_DW.DIM_DATE)
--   SET / table options / COMPRESS / FORMAT / stats / NUSI -> removed
--   UNIQUE PRIMARY INDEX (DATE_KEY) -> CLUSTER BY DATE_KEY + PRIMARY KEY NOT ENFORCED
--   SMALLINT / BYTEINT -> INT64; CHAR/VARCHAR -> STRING
CREATE TABLE IF NOT EXISTS banking_dw.dim_date (
    DATE_KEY             INT64  NOT NULL OPTIONS (description = 'YYYYMMDD'),
    CALENDAR_DATE        DATE   NOT NULL,
    DAY_OF_WEEK          INT64  NOT NULL OPTIONS (description = '1=Monday, 7=Sunday'),
    DAY_NAME             STRING NOT NULL,
    DAY_OF_MONTH         INT64  NOT NULL,
    DAY_OF_YEAR          INT64  NOT NULL,
    WEEK_OF_YEAR         INT64  NOT NULL,
    ISO_WEEK             INT64  NOT NULL,
    MONTH_NUM            INT64  NOT NULL,
    MONTH_NAME           STRING NOT NULL,
    MONTH_SHORT          STRING NOT NULL,
    QUARTER_NUM          INT64  NOT NULL,
    QUARTER_NAME         STRING NOT NULL,
    HALF_YEAR            INT64  NOT NULL,
    CALENDAR_YEAR        INT64  NOT NULL,
    FISCAL_YEAR          INT64  NOT NULL,
    FISCAL_QUARTER       INT64  NOT NULL,
    IS_WEEKEND           INT64  NOT NULL,
    IS_NORWEGIAN_HOLIDAY INT64  DEFAULT 0,
    HOLIDAY_NAME         STRING,
    IS_BUSINESS_DAY      INT64  NOT NULL,
    IS_MONTH_END         INT64  NOT NULL,
    IS_QUARTER_END       INT64  NOT NULL,
    IS_YEAR_END          INT64  NOT NULL,
    PRIOR_DAY_DATE       DATE,
    NEXT_DAY_DATE        DATE,
    SAME_DAY_PREV_YEAR   DATE,
    PRIMARY KEY (DATE_KEY) NOT ENFORCED
)
CLUSTER BY DATE_KEY, CALENDAR_DATE
OPTIONS (description = 'Calendar dimension with Norwegian holidays and fiscal year alignment');
