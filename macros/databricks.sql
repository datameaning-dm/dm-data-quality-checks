{#-
  Databricks: row-level rules become expectations (Lakeflow Spark Declarative Pipelines, formerly DLT).
    not_null        col IS NOT NULL
    accepted_values col IN ('a', 'b')
    range           col >= min AND col <= max
    expression      the expression as written
  They are written to a rules table (name, constraint, tag, ...) that Python pipelines read with
  dp.expect_all*, and printed as CONSTRAINT ... EXPECT clauses for SQL pipelines.
  databricks_action: check_constraint instead adds a Delta CHECK constraint, which rejects bad writes.
  unique, freshness, row_count_min and custom are not row-level, so they have no Databricks expectation.
-#}

{% macro native_dq_databricks_constraint(rule) %}
  {%- set c = (rule.column or '') | lower -%}
  {%- if rule.type == 'not_null' -%}
    {{ return(c ~ ' IS NOT NULL') }}
  {%- elif rule.type == 'accepted_values' -%}
    {%- set lits = [] -%}
    {%- for v in rule['values'] -%}{%- do lits.append(native_dq.native_dq_literal(v)) -%}{%- endfor -%}
    {{ return(c ~ ' IN (' ~ lits | join(', ') ~ ')') }}
  {%- elif rule.type == 'range' -%}
    {%- set parts = [] -%}
    {%- if rule.min is not none -%}{%- do parts.append(c ~ ' >= ' ~ rule.min) -%}{%- endif -%}
    {%- if rule.max is not none -%}{%- do parts.append(c ~ ' <= ' ~ rule.max) -%}{%- endif -%}
    {{ return(parts | join(' AND ')) }}
  {%- elif rule.type == 'expression' -%}
    {{ return(rule.expression) }}
  {%- endif -%}
  {{ return(none) }}
{% endmacro %}

{% macro native_dq_databricks_name(rule) %}
  {{ return(rule.expectation_name | lower) }}
{% endmacro %}

{% macro native_dq_databricks_fqn(target) %}
  {{ return((target.database ~ '.' ~ target.schema ~ '.' ~ target.identifier) | lower) }}
{% endmacro %}

{% macro native_dq_databricks_tag(target) %}
  {{ return((target.schema ~ '.' ~ target.identifier) | lower) }}
{% endmacro %}

{% macro native_dq_databricks_rules_table(database) %}
  {{ return((database ~ '.' ~ var('native_dq_databricks_rules_table', 'dq_ops.dq_rules')) | lower) }}
{% endmacro %}

{#- The rules table, created once per catalog. -#}
{% macro native_dq_databricks_setup(entries) %}
  {%- set out = [] -%}
  {%- set catalogs = [] -%}
  {%- for e in entries if e.target.database | lower not in catalogs -%}
    {%- do catalogs.append(e.target.database | lower) -%}
  {%- endfor -%}
  {%- for cat in catalogs | sort -%}
    {%- set table = native_dq.native_dq_databricks_rules_table(cat) -%}
    {%- do out.append('CREATE SCHEMA IF NOT EXISTS ' ~ table.rsplit('.', 1)[0]) -%}
    {%- do out.append('CREATE TABLE IF NOT EXISTS ' ~ table ~ ' (\n  name STRING,\n  `constraint` STRING,\n'
        ~ '  tag STRING,\n  action STRING,\n  rule_id STRING,\n  dimension STRING,\n  severity STRING,\n'
        ~ '  threshold INT,\n  steward STRING\n)') -%}
  {%- endfor -%}
  {{ return(out) }}
{% endmacro %}

{% macro native_dq_databricks_statements(entry) %}
  {%- set t = entry.target -%}
  {%- set fqn = native_dq.native_dq_databricks_fqn(t) -%}
  {%- set table = native_dq.native_dq_databricks_rules_table(t.database) -%}
  {%- set tag = native_dq.native_dq_databricks_tag(t) -%}
  {%- set out = ['-- ' ~ t.unique_id ~ ' -> ' ~ fqn] -%}
  {%- set rows = [] -%}
  {%- for r in entry.rules -%}
    {%- set constraint = native_dq.native_dq_databricks_constraint(r) -%}
    {%- set name = native_dq.native_dq_databricks_name(r) -%}
    {%- if constraint is none -%}
      {%- do out.append('-- rule ' ~ r.id ~ ' skipped: ' ~ r.type ~ ' is not a row-level expectation on Databricks') -%}
    {%- else -%}
      {%- if r.databricks_action == 'check_constraint' -%}
        {%- do out.append('ALTER TABLE ' ~ fqn ~ ' DROP CONSTRAINT IF EXISTS ' ~ name) -%}
        {%- if r.status == 'active' -%}
          {%- do out.append('ALTER TABLE ' ~ fqn ~ ' ADD CONSTRAINT ' ~ name ~ ' CHECK (' ~ constraint ~ ')') -%}
        {%- endif -%}
      {%- endif -%}
      {%- if r.status == 'active' -%}
        {%- do rows.append('(' ~ [
              native_dq.native_dq_literal(name),
              native_dq.native_dq_databricks_string(constraint),
              native_dq.native_dq_literal(tag),
              native_dq.native_dq_literal(r.databricks_action),
              native_dq.native_dq_literal(r.id),
              native_dq.native_dq_literal(r.dimension),
              native_dq.native_dq_literal(r.severity),
              r.threshold | string,
              native_dq.native_dq_literal(r.steward)] | join(', ') ~ ')') -%}
      {%- endif -%}
    {%- endif -%}
  {%- endfor -%}
  {%- do out.append('DELETE FROM ' ~ table ~ ' WHERE tag = ' ~ native_dq.native_dq_literal(tag)) -%}
  {%- if rows | length > 0 -%}
    {%- do out.append('INSERT INTO ' ~ table ~ ' VALUES\n  ' ~ rows | join(',\n  ')) -%}
  {%- endif -%}
  {{ return(out) }}
{% endmacro %}

{#- CONSTRAINT ... EXPECT clauses to paste into a SQL pipeline's CREATE OR REFRESH STREAMING TABLE or
    MATERIALIZED VIEW. SQL pipelines cannot load expectations from a table, so they are generated here. -#}
{% macro native_dq_databricks_pipeline_clauses(entry) %}
  {%- set clauses = [] -%}
  {%- for r in entry.rules if r.status == 'active' and r.databricks_action in ['warn', 'drop', 'fail'] -%}
    {%- set constraint = native_dq.native_dq_databricks_constraint(r) -%}
    {%- if constraint is not none -%}
      {%- set on = {'warn': '', 'drop': ' ON VIOLATION DROP ROW', 'fail': ' ON VIOLATION FAIL UPDATE'}[r.databricks_action] -%}
      {%- do clauses.append('CONSTRAINT ' ~ native_dq.native_dq_databricks_name(r) ~ ' EXPECT (' ~ constraint ~ ')' ~ on) -%}
    {%- endif -%}
  {%- endfor -%}
  {{ return(clauses) }}
{% endmacro %}
