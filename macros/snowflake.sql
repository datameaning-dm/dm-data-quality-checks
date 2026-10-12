{#-
  Snowflake: each rule becomes a data metric function (DMF) attached to its table, with an expectation.
    not_null        SNOWFLAKE.CORE.NULL_COUNT       ON (col)                 EXPECTATION (VALUE <= threshold)
    unique          SNOWFLAKE.CORE.DUPLICATE_COUNT  ON (col)                 EXPECTATION (VALUE <= threshold)
    accepted_values SNOWFLAKE.CORE.ACCEPTED_VALUES  ON (col, col -> col IN …) EXPECTATION (VALUE <= threshold)
    freshness       SNOWFLAKE.CORE.FRESHNESS        ON (col)                 EXPECTATION (VALUE <= max_age_seconds)
    row_count_min   SNOWFLAKE.CORE.ROW_COUNT        ON ()                    EXPECTATION (VALUE >= min_rows)
    range, expression, custom: a custom DMF of the rule's own, counting failing rows.
-#}

{% macro native_dq_snowflake_system_dmf(rule) %}
  {{ return({
      'not_null': 'SNOWFLAKE.CORE.NULL_COUNT',
      'unique': 'SNOWFLAKE.CORE.DUPLICATE_COUNT',
      'accepted_values': 'SNOWFLAKE.CORE.ACCEPTED_VALUES',
      'freshness': 'SNOWFLAKE.CORE.FRESHNESS',
      'row_count_min': 'SNOWFLAKE.CORE.ROW_COUNT',
  }.get(rule.type)) }}
{% endmacro %}

{% macro native_dq_snowflake_fqn(target) %}
  {{ return((target.database ~ '.' ~ target.schema ~ '.' ~ target.identifier) | upper) }}
{% endmacro %}

{% macro native_dq_snowflake_custom_name(target, rule) %}
  {{ return((target.database ~ '.' ~ var('native_dq_dmf_schema', 'DATA_QUALITY') ~ '.' ~ rule.expectation_name) | upper) }}
{% endmacro %}

{#- The failing-row query for rules that need a custom DMF. T is the DMF's table argument. -#}
{% macro native_dq_snowflake_custom_body(rule) %}
  {%- if rule.type == 'range' -%}
    {%- set parts = [] -%}
    {%- if rule.min is not none -%}{%- do parts.append(rule.column ~ ' < ' ~ rule.min) -%}{%- endif -%}
    {%- if rule.max is not none -%}{%- do parts.append(rule.column ~ ' > ' ~ rule.max) -%}{%- endif -%}
    {{ return('SELECT COUNT(*) FROM T WHERE ' ~ parts | join(' OR ')) }}
  {%- elif rule.type == 'expression' -%}
    {{ return('SELECT COUNT(*) FROM T WHERE NOT (' ~ rule.expression ~ ')') }}
  {%- elif rule.type == 'custom' -%}
    {{ return(rule.sql) }}
  {%- endif -%}
  {{ return(none) }}
{% endmacro %}

{#- TABLE(<col> <type>, ...) for the custom DMF signature. Types come from the columns' data_type in YAML. -#}
{% macro native_dq_snowflake_signature(target, rule, with_names=true) %}
  {%- set parts = [] -%}
  {%- for c in rule.columns -%}
    {%- set dtype = target.columns.get(c) -%}
    {%- if not dtype -%}
      {{ exceptions.raise_compiler_error("native_dq: rule '" ~ rule.id ~ "' on " ~ target.unique_id
          ~ " builds a custom data metric function, which needs the data_type of column " ~ c
          ~ ". Declare it under columns: in the YAML.") }}
    {%- endif -%}
    {%- if modules.re.match('^[A-Za-z_][A-Za-z0-9_]*( ?\\([0-9, ]+\\))?$', dtype) is none -%}
      {{ exceptions.raise_compiler_error("native_dq: data_type '" ~ dtype ~ "' of " ~ c ~ " is not a plain type") }}
    {%- endif -%}
    {%- do parts.append((c ~ ' ' ~ dtype) if with_names else dtype) -%}
  {%- endfor -%}
  {{ return('TABLE(' ~ (parts | join(', ') | upper) ~ ')') }}
{% endmacro %}

{#- The DMF and its ON (...) arguments, as attached to the table. -#}
{% macro native_dq_snowflake_attachment(target, rule) %}
  {%- set dmf = native_dq.native_dq_snowflake_system_dmf(rule) -%}
  {%- if rule.type == 'accepted_values' -%}
    {%- set lits = [] -%}
    {%- for v in rule['values'] -%}{%- do lits.append(native_dq.native_dq_literal(v)) -%}{%- endfor -%}
    {%- set args = rule.column ~ ', ' ~ rule.column ~ ' -> ' ~ rule.column ~ ' IN (' ~ lits | join(', ') ~ ')' -%}
  {%- elif rule.type == 'row_count_min' -%}
    {%- set args = '' -%}
  {%- elif dmf -%}
    {%- set args = rule.column -%}
  {%- else -%}
    {%- set dmf = native_dq.native_dq_snowflake_custom_name(target, rule) -%}
    {%- set args = rule.columns | join(', ') -%}
  {%- endif -%}
  {{ return(dmf ~ ' ON (' ~ args ~ ')') }}
{% endmacro %}

{% macro native_dq_snowflake_expectation(rule) %}
  {%- if rule.type == 'freshness' -%}
    {{ return('VALUE <= ' ~ rule.max_age_seconds) }}
  {%- elif rule.type == 'row_count_min' -%}
    {{ return('VALUE >= ' ~ rule.min_rows) }}
  {%- endif -%}
  {{ return('VALUE <= ' ~ rule.threshold) }}
{% endmacro %}

{#- Statements for one table. Safe to run again: each check is detached (if attached) and re-added,
    which is also what restores checks after CREATE OR REPLACE dropped them. -#}
{% macro native_dq_snowflake_statements(entry) %}
  {%- set t = entry.target -%}
  {%- set fqn = native_dq.native_dq_snowflake_fqn(t) -%}
  {%- set role = var('native_dq_execute_as_role', none) -%}
  {%- set out = ['-- ' ~ t.unique_id ~ ' -> ' ~ fqn] -%}
  {%- set active = entry.rules | selectattr('status', 'equalto', 'active') | list -%}
  {%- if active | length > 0 -%}
    {%- do out.append('ALTER ' ~ t.kind ~ ' ' ~ fqn ~ " SET DATA_METRIC_SCHEDULE = '" ~ t.schedule ~ "'") -%}
  {%- endif -%}
  {%- for r in entry.rules -%}
    {%- set attachment = native_dq.native_dq_snowflake_attachment(t, r) -%}
    {%- set custom = native_dq.native_dq_snowflake_system_dmf(r) is none -%}
    {%- do out.append('-- rule ' ~ r.id ~ ' (' ~ r.type ~ ', ' ~ r.status ~ ')') -%}
    {%- do out.append('EXECUTE IMMEDIATE $$\nBEGIN\n  ALTER ' ~ t.kind ~ ' ' ~ fqn
        ~ ' DROP DATA METRIC FUNCTION ' ~ attachment ~ ';\nEXCEPTION\n  WHEN OTHER THEN NULL;\nEND;\n$$') -%}
    {%- if r.status == 'active' -%}
      {%- if custom -%}
        {%- do out.append('CREATE OR REPLACE DATA METRIC FUNCTION ' ~ native_dq.native_dq_snowflake_custom_name(t, r)
            ~ '(T ' ~ native_dq.native_dq_snowflake_signature(t, r) ~ ')\n  RETURNS NUMBER\n  COMMENT = '
            ~ native_dq.native_dq_literal('native_dq rule ' ~ r.id ~ ': ' ~ r.name)
            ~ '\n  AS $$' ~ native_dq.native_dq_snowflake_custom_body(r) ~ '$$') -%}
      {%- endif -%}
      {%- do out.append('ALTER ' ~ t.kind ~ ' ' ~ fqn ~ '\n  ADD DATA METRIC FUNCTION ' ~ attachment
          ~ ('\n  EXECUTE AS ROLE ' ~ role | upper if role else '')
          ~ '\n  EXPECTATION ' ~ r.expectation_name ~ ' (' ~ native_dq.native_dq_snowflake_expectation(r) ~ ')') -%}
    {%- elif custom -%}
      {%- do out.append('DROP FUNCTION IF EXISTS ' ~ native_dq.native_dq_snowflake_custom_name(t, r)
          ~ '(' ~ native_dq.native_dq_snowflake_signature(t, r, with_names=false) ~ ')') -%}
    {%- endif -%}
  {%- endfor -%}
  {{ return(out) }}
{% endmacro %}

{#- Schemas that must exist before custom DMFs are created (one per database). -#}
{% macro native_dq_snowflake_setup(entries) %}
  {%- set dbs = [] -%}
  {%- for e in entries -%}
    {%- for r in e.rules if r.status == 'active' and native_dq.native_dq_snowflake_system_dmf(r) is none -%}
      {%- if e.target.database | upper not in dbs -%}{%- do dbs.append(e.target.database | upper) -%}{%- endif -%}
    {%- endfor -%}
  {%- endfor -%}
  {%- set out = [] -%}
  {%- for db in dbs | sort -%}
    {%- do out.append('CREATE SCHEMA IF NOT EXISTS ' ~ db ~ '.' ~ var('native_dq_dmf_schema', 'DATA_QUALITY') | upper) -%}
  {%- endfor -%}
  {{ return(out) }}
{% endmacro %}
