# Teradata -> BigQuery cutover runbook

Gate for every phase: the parity checks in `verify/checks/*.sql`, compared against
`verify/expected/parity_checksums.csv` locally (`python verify/run_parity.py` must print
`RESULT: PASS`), and compared between Teradata and BigQuery during the dual run.

## 0. Deploy objects (dataset `banking_dw`)

Order: `tables/01..09` -> `views/01..03` -> `table_functions/*` -> `procedures/*`.
`views/*.sql` use unqualified table names (the parity harness runs them as-is); deploy them
with `bq query --dataset_id=<project>:banking_dw` so names resolve to `banking_dw`.

## 1. History backfill

1. Freeze the Teradata batch at a known `ETL_BATCH_ID` (cut-off batch `B0`).
2. Export each table with TPT (or the BigQuery Migration Service Teradata transfer) to GCS
   as Parquet/Avro; `fact_transaction` and `fact_monthly_account_snapshot` export one file
   set per month to match the monthly partitions.
3. `bq load` into the `*_history` dimensions and the facts. Fill the natural keys
   `ACCOUNT_ID` / `CUSTOMER_ID` on the facts from the dimension surrogate keys while loading.
4. Check row counts and `SUM(BASE_CURRENCY_AMOUNT)` per month on both sides.
5. Run the parity checks (step 2) on the backfilled data; they must match Teradata before the
   dual run starts.

## 2. Dual-run reconciliation (same checks as the red/green gate)

1. Run Teradata BTEQ jobs and the BigQuery jobs (`scripts/daily_load.sql`, monthly
   `sp_monthly_snapshot` + `scripts/monthly_extract.sql`) on the same staging files every day.
2. After each run, execute every `verify/checks/*.sql` file on both systems. The check queries
   only use `COUNT`, `SUM`, `ROUND` and `COUNT(DISTINCT)`, so they run unchanged on both
   (on Teradata, point them at the source views `VW_REGULATORY_LARGE_TRANSACTIONS`,
   `VW_BRANCH_PERFORMANCE`, `VW_CUSTOMER_360`).
3. Compare metric by metric with the same tolerance as `verify/run_parity.py`. Any mismatch
   is red: stop, fix the BigQuery side, rerun. Never edit `verify/checks/` or
   `verify/expected/` to get green.
4. Also compare `etl_batch_control` (status per batch), `etl_log` row counts per level, and the
   exported report files (row count + checksum of sorted rows).
5. Exit criterion: green on all metrics for 10 consecutive business days and one month-end.

## 3. Consumer switchover

1. Repoint BI/reporting connections and regulatory extract delivery to BigQuery
   (`banking_dw` views and table functions), one consumer group at a time, starting with
   internal dashboards and ending with regulatory submissions.
2. Keep Teradata loading for one more month-end as a fallback; rollback = point consumers
   back to Teradata.
3. Stop the Teradata jobs, take a final export for archive, decommission.

## Known differences to review before cutover

- The parity model joins on natural keys (`ACCOUNT_ID`, `CUSTOMER_ID`, `BRANCH_ID`), so the
  facts carry those columns in addition to the surrogate keys.
- `vw_regulatory_large_transactions` exposes the columns present in the parity seed;
  `TRANSACTION_TS`, `TRANSACTION_SUBTYPE`, `COUNTERPARTY_ACCT`, `REFERENCE_NUMBER` and
  `DESCRIPTION_TEXT` are not in the view (the monthly extract joins `REFERENCE_NUMBER` back).
- `sp_monthly_snapshot` keeps a source bug: the previous-month lookup uses the first day of
  the previous month while snapshots are stored at month end, so `OPENING_BALANCE` is
  always 0. Fix it on both systems together, or after cutover.
- `SAMPLE 1000` (Teradata) and `ORDER BY RAND() LIMIT 1000` (BigQuery) both return random
  rows, so `tvf_customer_txn_history` cannot be reconciled row by row; compare filtered counts.
- Staging/control table DDL (`tables/09_etl_support.sql`) is inferred from the DML because
  the Teradata DDL for those tables is not in this repo.
