# What runs as pure SQL vs. what needs orchestration

| Teradata object | BigQuery equivalent | Pure SQL? | Orchestration needed |
|---|---|---|---|
| `SP_CUSTOMER_SCD2` | `procedures/sp_customer_scd2.sql` (single `MERGE`) | Yes | Called by the daily load |
| `SP_LOAD_DAILY_TRANSACTIONS` | `procedures/sp_load_daily_transactions.sql` | Yes, once staging is filled | Landing files into `stg_transactions` (TPT/FastLoad today) becomes a GCS load job (`bq load` / Storage Write API), or Dataflow if files need parsing or cleansing in flight |
| `SP_MONTHLY_SNAPSHOT` | `procedures/sp_monthly_snapshot.sql` (temp table + `MERGE`) | Yes | Monthly schedule (1st day, after the daily load) |
| `AML_SCREENING` macro | `table_functions/tvf_aml_screening.sql` (3 TVFs) | Yes | None; callers query each TVF |
| `CUSTOMER_TXN_HISTORY` macro | `table_functions/tvf_customer_txn_history.sql` | Yes | None |
| `DAILY_BALANCE_CHECK` macro | `table_functions/tvf_daily_balance_check.sql` (2 TVFs) | Yes | None |
| `bteq_daily_load.btq` | `scripts/daily_load.sql` | Script is pure SQL | Daily trigger, staging-ready dependency, `@gcs_report_uri` parameter, alerting on job failure (replaces `.QUIT 8`) and on `WARN` rows in `etl_log` (replaces `.QUIT 4`) |
| `bteq_extract_report.btq` | `scripts/monthly_extract.sql` (`EXPORT DATA` to GCS) | Script is pure SQL | Monthly trigger, `@gcs_prefix` parameter, delivery of the GCS files to the regulator/SFTP; fixed-width `.rpt` formatting if still required |

## Recommended setup

- **Daily load**: Cloud Composer (Airflow) DAG:
  `GCSObjectExistenceSensor` (staging files) -> `bq load` into `stg_transactions` / `stg_customer`
  -> `BigQueryInsertJobOperator` running `scripts/daily_load.sql` -> alert on failure.
  A BigQuery scheduled query can run `daily_load.sql` alone, but it cannot wait for files or load them, so Composer (or Workflows) is needed for the full pipeline.
- **Monthly snapshot + extracts**: the same DAG on a monthly schedule:
  `CALL banking_dw.sp_monthly_snapshot(year, month, batch_id, ...)` then `scripts/monthly_extract.sql`, then a GCS -> SFTP transfer for the regulator.
- **Dataflow** is only needed if staging needs record-level parsing or validation before it lands in BigQuery. The Teradata jobs do not do this; the BigQuery equivalent of the TPT load is a plain `bq load`.

## BTEQ control-flow mapping

| BTEQ | BigQuery scripting / orchestrator |
|---|---|
| `.LOGON` | Service account on the job |
| `DATABASE BANKING_DW` | Fully qualified `banking_dw.` names (or job default dataset) |
| `.IF ACTIVITYCOUNT = 0 THEN .GOTO X` | `IF (SELECT COUNT(*) ...) = 0 THEN ... RETURN; END IF;` |
| `.IF ERRORCODE <> 0 THEN .GOTO ERRORHANDLER` | `BEGIN ... EXCEPTION WHEN ERROR THEN ... END;` |
| `.QUIT 0 / 4 / 8` | Success / `WARN` row in `etl_log` + `RETURN` / `RAISE` (failed job) |
| Volatile table | Script variables or `CREATE TEMP TABLE` |
| `.EXPORT DATA/REPORT FILE=` | `EXPORT DATA OPTIONS(uri='gs://...')` |
