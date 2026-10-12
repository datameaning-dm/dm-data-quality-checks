{#- One row per declared rule: what it checks, who stewards it, and the name its results carry.
    Built from the YAML at run time, so it always matches what was deployed from this commit. -#}
{%- set platform = native_dq.native_dq_platform() -%}
{%- set entries = native_dq.native_dq_collect() -%}
{%- set s = dbt.type_string() -%}
{%- set rows = [] -%}
{%- for e in entries -%}
  {%- for r in e.rules -%}
    {%- set result_name = r.expectation_name | lower if platform == 'databricks' else r.expectation_name -%}
    {%- set table_name = native_dq.native_dq_databricks_fqn(e.target) if platform == 'databricks'
                         else native_dq.native_dq_snowflake_fqn(e.target) -%}
    {%- do rows.append([
        r.id, result_name, table_name, e.target.identifier | upper, r.column or '', r.type,
        r.dimension, r.severity, r.steward, r.threshold | string, r.status, r.name, r.description]) -%}
  {%- endfor -%}
{%- endfor -%}
{%- set cols = ['rule_id', 'result_name', 'table_full_name', 'table_name', 'column_name', 'rule_type',
                'dimension', 'severity', 'steward', 'threshold', 'status', 'rule_name', 'description'] -%}

{%- if rows | length == 0 %}
select
  {%- for c in cols %}
  cast(null as {{ s }}) as {{ c }}{{ ',' if not loop.last }}
  {%- endfor %}
where 1 = 0
{%- else %}
{%- for row in rows %}
select
  {%- for c in cols %}
  {%- if c == 'threshold' %}
  cast({{ row[loop.index0] }} as integer) as {{ c }}{{ ',' if not loop.last }}
  {%- else %}
  cast('{{ row[loop.index0] }}' as {{ s }}) as {{ c }}{{ ',' if not loop.last }}
  {%- endif %}
  {%- endfor %}
{{ 'union all' if not loop.last }}
{%- endfor %}
{%- endif %}
