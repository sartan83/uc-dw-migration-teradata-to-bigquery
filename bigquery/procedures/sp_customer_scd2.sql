-- Source: dml/stored_procedures/sp_customer_scd2.sql (Teradata SP_CUSTOMER_SCD2)
-- Teradata: UPDATE ... FROM (expire) + INSERT ... SEL (new versions / new customers),
--           ACTIVITY_COUNT, COLLECT STATISTICS.
-- BigQuery: one atomic MERGE using the "null merge key" SCD2 pattern:
--   * every staged row joins on CUSTOMER_ID -> WHEN MATCHED (changed) expires the
--     current version;
--   * changed rows are emitted a second time with MERGE_KEY = NULL -> never match
--     -> WHEN NOT MATCHED inserts the new current version;
--   * brand-new customers have no current row -> WHEN NOT MATCHED inserts them.
-- Change detection keeps the Teradata predicate verbatim ("<>" on nullable
-- columns, COALESCE only on PHONE_NUMBER / EMAIL_ADDRESS) so dual-run results
-- match the source system.
-- IDENTITY surrogate key -> MAX(CUSTOMER_KEY) + ROW_NUMBER() (single-writer job).
-- ACTIVITY_COUNT -> counts taken from the staged change set (MERGE @@row_count
-- reports expire + insert together). COLLECT STATISTICS -> removed.
CREATE OR REPLACE PROCEDURE banking_dw.sp_customer_scd2(
    IN p_batch_id INT64,
    OUT p_new_rows INT64,
    OUT p_changed INT64,
    OUT p_return_code INT64
)
BEGIN
    DECLARE v_current_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
    DECLARE v_max_key INT64;

    SET p_return_code = 0;
    SET p_new_rows = 0;
    SET p_changed = 0;

    SET v_max_key = (SELECT IFNULL(MAX(CUSTOMER_KEY), 0)
                     FROM banking_dw.dim_customer_history);

    CREATE TEMP TABLE scd2_changes AS
    SELECT
        stg.*,
        dim.CUSTOMER_ID IS NULL AS IS_NEW,
        prev.ONBOARDING_DATE AS PRIOR_ONBOARDING_DATE,
        v_max_key + ROW_NUMBER() OVER (ORDER BY stg.CUSTOMER_ID) AS NEW_CUSTOMER_KEY
    FROM banking_dw.stg_customer stg
    LEFT JOIN banking_dw.dim_customer_history dim
        ON stg.CUSTOMER_ID = dim.CUSTOMER_ID
       AND dim.CURRENT_FLAG = 'Y'
    LEFT JOIN (
        SELECT CUSTOMER_ID, ONBOARDING_DATE
        FROM banking_dw.dim_customer_history
        WHERE TRUE
        QUALIFY ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID
                                   ORDER BY EFFECTIVE_TO DESC) = 1
    ) prev
        ON stg.CUSTOMER_ID = prev.CUSTOMER_ID
    WHERE dim.CUSTOMER_ID IS NULL
       OR stg.CUSTOMER_SEGMENT <> dim.CUSTOMER_SEGMENT
       OR stg.RISK_SCORE <> dim.RISK_SCORE
       OR stg.CREDIT_RATING <> dim.CREDIT_RATING
       OR stg.KYC_STATUS <> dim.KYC_STATUS
       OR stg.ADDRESS_LINE_1 <> dim.ADDRESS_LINE_1
       OR stg.CITY <> dim.CITY
       OR stg.STATE_PROVINCE <> dim.STATE_PROVINCE
       OR stg.POSTAL_CODE <> dim.POSTAL_CODE
       OR COALESCE(stg.PHONE_NUMBER, '') <> COALESCE(dim.PHONE_NUMBER, '')
       OR COALESCE(stg.EMAIL_ADDRESS, '') <> COALESCE(dim.EMAIL_ADDRESS, '')
       OR stg.MARITAL_STATUS <> dim.MARITAL_STATUS;

    SET p_changed = (SELECT COUNTIF(NOT IS_NEW) FROM scd2_changes);
    SET p_new_rows = (SELECT COUNT(*) FROM scd2_changes);

    MERGE banking_dw.dim_customer_history tgt
    USING (
        SELECT CUSTOMER_ID AS MERGE_KEY, ch.* FROM scd2_changes ch WHERE NOT IS_NEW
        UNION ALL
        SELECT CAST(NULL AS INT64) AS MERGE_KEY, ch.* FROM scd2_changes ch
    ) src
    ON tgt.CUSTOMER_ID = src.MERGE_KEY
       AND tgt.CURRENT_FLAG = 'Y'
    WHEN MATCHED THEN UPDATE SET
        CURRENT_FLAG  = 'N',
        EFFECTIVE_TO  = v_current_ts,
        ETL_UPDATE_TS = v_current_ts,
        ETL_BATCH_ID  = p_batch_id
    WHEN NOT MATCHED THEN INSERT (
        CUSTOMER_ID, CUSTOMER_KEY, FIRST_NAME, LAST_NAME, DATE_OF_BIRTH, GENDER,
        MARITAL_STATUS, EMAIL_ADDRESS, PHONE_NUMBER,
        ADDRESS_LINE_1, ADDRESS_LINE_2, CITY, STATE_PROVINCE,
        POSTAL_CODE, COUNTRY_CODE, CUSTOMER_SEGMENT, RISK_SCORE,
        CREDIT_RATING, KYC_STATUS, ONBOARDING_DATE, LAST_REVIEW_DATE,
        IS_ACTIVE, EFFECTIVE_FROM, EFFECTIVE_TO, CURRENT_FLAG,
        ETL_BATCH_ID, ETL_INSERT_TS, ETL_UPDATE_TS
    ) VALUES (
        src.CUSTOMER_ID,
        src.NEW_CUSTOMER_KEY,
        src.FIRST_NAME, src.LAST_NAME, src.DATE_OF_BIRTH, src.GENDER,
        src.MARITAL_STATUS, src.EMAIL_ADDRESS, src.PHONE_NUMBER,
        src.ADDRESS_LINE_1, src.ADDRESS_LINE_2, src.CITY, src.STATE_PROVINCE,
        src.POSTAL_CODE, COALESCE(src.COUNTRY_CODE, 'NOR'), src.CUSTOMER_SEGMENT, src.RISK_SCORE,
        src.CREDIT_RATING, src.KYC_STATUS,
        COALESCE(src.PRIOR_ONBOARDING_DATE, CURRENT_DATE()), CURRENT_DATE(),
        1, v_current_ts, TIMESTAMP '9999-12-31 23:59:59+00', 'Y',
        p_batch_id, v_current_ts, v_current_ts
    );

    DROP TABLE scd2_changes;
END;
