{#-
  dbt run-operation native_dq_local_evaluate

  Runs each rule's logic as a plain SQL count on whatever adapter you are connected to (DuckDB in the
  tests), and prints the failing-row count and pass or fail. It checks the rules against sample data
  before they go anywhere near Snowflake or Databricks. It does not use the native features.
  freshness is skipped: its result depends on the clock.
-#}

{% macro native_dq_local_count_sql(entry, rule) %}
  {%- set rel = adapter.quote(entry.target.database) ~ '.' ~ adapter.quote(entry.target.schema) ~ '.'
                ~ adapter.quote(entry.target.identifier) -%}
  {%- set c = rule.column -%}
  {%- if rule.type == 'not_null' -%}
    {{ return('select count(*) from ' ~ rel ~ ' where ' ~ c ~ ' is null') }}
  {%- elif rule.type == 'unique' -%}
    {{ return('select count(' ~ c ~ ') - count(distinct ' ~ c ~ ') from ' ~ rel) }}
  {%- elif rule.type == 'accepted_values' -%}
    {%- set lits = [] -%}
    {%- for v in rule['values'] -%}{%- do lits.append(native_dq.native_dq_literal(v)) -%}{%- endfor -%}
    {{ return('select count(*) from ' ~ rel ~ ' where not (' ~ c ~ ' in (' ~ lits | join(', ') ~ '))') }}
  {%- elif rule.type in ['range', 'expression'] -%}
    {{ return('select count(*) from ' ~ rel ~ ' where not (' ~ native_dq.native_dq_databricks_constraint(rule) ~ ')') }}
  {%- elif rule.type == 'custom' -%}
    {{ return(modules.re.sub('\\bT\\b', rel, rule.sql)) }}
  {%- elif rule.type == 'row_count_min' -%}
    {{ return('select count(*) from ' ~ rel) }}
  {%- endif -%}
  {{ return(none) }}
{% endmacro %}

{% macro native_dq_local_evaluate(select=none) %}
  {%- set entries = native_dq.native_dq_collect(select) -%}
  {%- set failed = [] -%}
  {%- for e in entries -%}
    {%- for r in e.rules if r.status == 'active' -%}
      {%- set sql = native_dq.native_dq_local_count_sql(e, r) -%}
      {%- if sql is none -%}
        {% do print('native_dq_local ' ~ r.id ~ ' skipped') %}
      {%- else -%}
        {%- set value = run_query(sql).columns[0].values()[0] | int -%}
        {%- if r.type == 'row_count_min' -%}
          {%- set ok = value >= r.min_rows -%}
        {%- else -%}
          {%- set ok = value <= r.threshold -%}
        {%- endif -%}
        {%- if not ok -%}{%- do failed.append(r.id) -%}{%- endif -%}
        {% do print('native_dq_local ' ~ r.id ~ ' ' ~ value ~ ' ' ~ ('pass' if ok else 'fail')) %}
      {%- endif -%}
    {%- endfor -%}
  {%- endfor -%}
  {% do print('native_dq_local: ' ~ failed | length ~ ' rule(s) failing') %}
{% endmacro %}
