{#- Pass rate per rule per day. Aggregate in Power BI by table, column or dimension for trends. -#}
select
  measured_date,
  rule_id,
  rule_name,
  table_full_name,
  table_name,
  column_name,
  dimension,
  severity,
  steward,
  count(*)                                        as checks_run,
  sum(passed_flag)                                as checks_passed,
  count(*) - sum(passed_flag)                     as checks_failed,
  cast(sum(passed_flag) as double) / count(*)     as pass_rate
from {{ ref('dq_results') }}
group by
  measured_date, rule_id, rule_name, table_full_name, table_name, column_name, dimension, severity, steward
