{#- Every check result, one row per rule per run, joined to the rule catalog.
    Snowflake: the expectation status view Snowflake fills when a DMF runs.
    Databricks: expectation counts from the pipeline event log.
    local: synthetic results from the model named by var native_dq_local_results (demo and tests). -#}
{%- set platform = native_dq.native_dq_platform() -%}

with rules as (
  select * from {{ ref('dq_rule_catalog') }}
),

{% if platform == 'snowflake' %}
raw as (
  select
    s.measurement_time                                            as measured_at,
    upper(s.table_database || '.' || s.table_schema || '.' || s.table_name) as table_full_name,
    upper(s.expectation_name)                                     as result_name,
    try_to_double(to_varchar(s.value))                            as metric_value,
    not s.expectation_violated                                    as passed
  from snowflake.local.data_quality_monitoring_expectation_status s
  where startswith(upper(s.expectation_name), '{{ native_dq.native_dq_prefix() | upper }}')
)
{% elif platform == 'databricks' %}
{%- set event_log = var('native_dq_databricks_event_log', none) -%}
{%- if not event_log and execute -%}
  {{ exceptions.raise_compiler_error("native_dq: set var native_dq_databricks_event_log, for example "
      ~ "\"event_log('<pipeline id>')\" or a published event log table") }}
{%- endif %}
expectations as (
  select
    e.timestamp as measured_at,
    explode(from_json(
      e.details:flow_progress.data_quality.expectations,
      'array<struct<name:string,dataset:string,passed_records:bigint,failed_records:bigint>>'
    )) as x
  from {{ event_log or "event_log('<pipeline id>')" }} e
  where e.event_type = 'flow_progress'
),
raw as (
  select
    measured_at,
    lower(x.dataset)                    as dataset,
    lower(x.name)                       as result_name,
    cast(x.failed_records as double)    as metric_value,
    cast(x.passed_records as double)    as passed_records
  from expectations
)
{% else %}
raw as (
  select
    cast(measured_at as timestamp)      as measured_at,
    upper(table_full_name)              as table_full_name,
    upper(result_name)                  as result_name,
    cast(metric_value as double)        as metric_value,
    cast(passed as boolean)             as passed
  from {{ ref(var('native_dq_local_results', 'dq_sample_results')) }}
)
{% endif %}

select
  r.measured_at,
  cast(r.measured_at as date)           as measured_date,
  c.rule_id,
  c.rule_name,
  c.table_full_name,
  c.table_name,
  c.column_name,
  c.rule_type,
  c.dimension,
  c.severity,
  c.steward,
  r.metric_value,
  {%- if platform == 'databricks' %}
  r.metric_value <= c.threshold         as passed,
  {%- else %}
  r.passed,
  {%- endif %}
  case when {{ 'r.metric_value <= c.threshold' if platform == 'databricks' else 'r.passed' }}
       then 1 else 0 end                as passed_flag
from raw r
join rules c
  on c.result_name = r.result_name
  {%- if platform != 'databricks' %}
 and c.table_full_name = r.table_full_name
  {%- endif %}
