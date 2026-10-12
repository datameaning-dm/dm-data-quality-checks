{#-
  Entry points.
    dbt run-operation native_dq_validate                     check every rule, change nothing
    dbt run-operation native_dq_deploy [--args '{select: orders}']   print (dry run) or run the native checks
    dbt run-operation native_dq_pipeline_sql                 Databricks: CONSTRAINT ... EXPECT clauses
    post-hook: "{{ native_dq.native_dq_apply() }}"           re-attach a model's checks after each build
-#}

{% macro native_dq_statements(entries) %}
  {%- set platform = native_dq.native_dq_platform() -%}
  {%- if platform == 'local' -%}
    {{ exceptions.raise_compiler_error("native_dq: deploy needs native_dq_platform snowflake or databricks") }}
  {%- endif -%}
  {%- set out = [] -%}
  {%- if platform == 'snowflake' -%}
    {%- do out.extend(native_dq.native_dq_snowflake_setup(entries)) -%}
    {%- for e in entries -%}{%- do out.extend(native_dq.native_dq_snowflake_statements(e)) -%}{%- endfor -%}
  {%- else -%}
    {%- do out.extend(native_dq.native_dq_databricks_setup(entries)) -%}
    {%- for e in entries -%}{%- do out.extend(native_dq.native_dq_databricks_statements(e)) -%}{%- endfor -%}
  {%- endif -%}
  {{ return(out) }}
{% endmacro %}

{% macro native_dq_validate() %}
  {%- set entries = native_dq.native_dq_collect() -%}
  {%- set n = [] -%}
  {%- for e in entries -%}
    {%- set active = e.rules | selectattr('status', 'equalto', 'active') | list -%}
    {%- do n.append(e.rules | length) -%}
    {% do print('-- ' ~ e.target.unique_id ~ ': ' ~ e.rules | length ~ ' rule(s), ' ~ active | length ~ ' active') %}
  {%- endfor -%}
  {#- Build the statements too, so platform-specific problems (a missing data_type) surface here. -#}
  {%- do native_dq.native_dq_statements(entries) -%}
  {% do print('native_dq: ' ~ n | sum ~ ' rule(s) on ' ~ entries | length ~ ' table(s) are valid for '
              ~ native_dq.native_dq_platform()) %}
{% endmacro %}

{% macro native_dq_deploy(select=none) %}
  {%- set entries = native_dq.native_dq_collect(select) -%}
  {%- do native_dq.native_dq_emit(native_dq.native_dq_statements(entries), 'deploy') -%}
{% endmacro %}

{% macro native_dq_pipeline_sql(select=none) %}
  {%- set entries = native_dq.native_dq_collect(select) -%}
  {% do print('-- native_dq: expectations for Databricks SQL pipelines. Paste each block into the column list') %}
  {% do print('-- of that table\'s CREATE OR REFRESH STREAMING TABLE / MATERIALIZED VIEW statement.') %}
  {%- for e in entries -%}
    {%- set clauses = native_dq.native_dq_databricks_pipeline_clauses(e) -%}
    {%- if clauses | length > 0 -%}
      {% do print('') %}
      {% do print('-- ' ~ native_dq.native_dq_databricks_fqn(e.target)) %}
      {% do print(clauses | join(',\n')) %}
    {%- endif -%}
  {%- endfor -%}
{% endmacro %}

{#- Post-hook. On Snowflake, CREATE OR REPLACE (every dbt table build) drops a table's DMFs, so the
    checks are put back right after the build. Runs nothing in a dry run, beyond printing. -#}
{% macro native_dq_apply() %}
  {%- if not execute -%}{{ return('') }}{%- endif -%}
  {%- set entry = native_dq.native_dq_node_rules(model) -%}
  {%- if entry and entry.rules | length > 0 -%}
    {%- do native_dq.native_dq_check_project([entry]) -%}
    {%- set statements = [] -%}
    {%- if native_dq.native_dq_platform() == 'snowflake' -%}
      {%- do statements.extend(native_dq.native_dq_snowflake_setup([entry])) -%}
      {%- do statements.extend(native_dq.native_dq_snowflake_statements(entry)) -%}
    {%- elif native_dq.native_dq_platform() == 'databricks' -%}
      {%- do statements.extend(native_dq.native_dq_databricks_setup([entry])) -%}
      {%- do statements.extend(native_dq.native_dq_databricks_statements(entry)) -%}
    {%- endif -%}
    {%- if statements | length > 0 -%}
      {%- do native_dq.native_dq_emit(statements, 'apply ' ~ model.name) -%}
    {%- endif -%}
  {%- endif -%}
  {{ return('') }}
{% endmacro %}
