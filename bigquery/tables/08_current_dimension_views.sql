-- Current-row views over the SCD2 history tables. They replace the
-- "AND x.CURRENT_FLAG = 'Y'" join predicates that every Teradata view, macro and
-- procedure repeated, and expose the natural-key model the analytic views in
-- bigquery/views/ (and the parity harness) are written against.
CREATE OR REPLACE VIEW banking_dw.dim_customer AS
SELECT * FROM banking_dw.dim_customer_history
WHERE CURRENT_FLAG = 'Y';

CREATE OR REPLACE VIEW banking_dw.dim_account AS
SELECT * FROM banking_dw.dim_account_history
WHERE CURRENT_FLAG = 'Y';
