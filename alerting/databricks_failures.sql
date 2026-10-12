-- Databricks SQL alert: failed expectations since the last run, for the dq_results view dbt built.
-- Create a Databricks SQL alert on this query (trigger when row count > 0) and add the stewards as
-- email destinations. Placeholders: <catalog>.<schema>.
-- Not yet run against a live Databricks workspace.
-- Docs: https://docs.databricks.com/aws/en/sql/user/alerts/
SELECT
  steward,
  severity,
  table_full_name,
  column_name,
  rule_name,
  rule_id,
  metric_value AS failed_records,
  measured_at
FROM <catalog>.<schema>.dq_results
WHERE NOT passed
  AND measured_at >= current_timestamp() - INTERVAL 1 HOUR
ORDER BY severity, table_full_name, rule_id;
