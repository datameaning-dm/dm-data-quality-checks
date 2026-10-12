{#- Settings and small helpers shared by every macro in the package. -#}

{% macro native_dq_platform() %}
  {%- set p = var('native_dq_platform', none) or target.type -%}
  {%- set p = p | lower -%}
  {%- if p not in ['snowflake', 'databricks', 'local'] -%}
    {{ exceptions.raise_compiler_error(
        "native_dq: platform '" ~ p ~ "' is not supported. Set var native_dq_platform to snowflake or databricks "
        ~ "(or local, for the synthetic demo results).") }}
  {%- endif -%}
  {{ return(p) }}
{% endmacro %}

{% macro native_dq_as_bool(value) %}
  {%- if value is string -%}
    {{ return(value | trim | lower in ['true', '1', 'yes', 'y']) }}
  {%- endif -%}
  {{ return(value is true or value == 1) }}
{% endmacro %}

{% macro native_dq_dry_run() %}
  {{ return(native_dq.native_dq_as_bool(var('native_dq_dry_run', true))) }}
{% endmacro %}

{% macro native_dq_prefix() %}
  {{ return(var('native_dq_prefix', 'DQ_')) }}
{% endmacro %}

{#- Plain, unquoted SQL identifier. Rule text ends up inside DDL, so nothing else is allowed. -#}
{% macro native_dq_is_identifier(name) %}
  {{ return(name is string and modules.re.match('^[A-Za-z_][A-Za-z0-9_]*$', name) is not none) }}
{% endmacro %}

{#- Free SQL text (an expression or a failing-row query) placed inside DDL or a $$ body. -#}
{% macro native_dq_check_sql_text(text, what, rule_id) %}
  {%- if text is not string or text | trim == '' -%}
    {{ exceptions.raise_compiler_error("native_dq: rule '" ~ rule_id ~ "' needs " ~ what ~ ".") }}
  {%- endif -%}
  {%- for bad in [';', '$$', '\\', '--', '/*'] -%}
    {%- if bad in text -%}
      {{ exceptions.raise_compiler_error(
          "native_dq: rule '" ~ rule_id ~ "': " ~ what ~ " may not contain '" ~ bad ~ "'.") }}
    {%- endif -%}
  {%- endfor -%}
{% endmacro %}

{#- A single-quoted SQL string literal. Values are validated to hold no quote or backslash. -#}
{% macro native_dq_literal(value) %}
  {{ return("'" ~ value ~ "'") }}
{% endmacro %}

{#- A string literal that may contain single quotes (expressions stored in the Databricks rules table).
    Databricks SQL escapes a quote with a backslash; backslashes themselves are refused upstream. -#}
{% macro native_dq_databricks_string(value) %}
  {{ return("'" ~ (value | replace("'", "\\'")) ~ "'") }}
{% endmacro %}

{#- Print statements (dry run) or run them one by one. Lines starting with -- are notes, never run. -#}
{% macro native_dq_emit(statements, title) %}
  {%- set dry = native_dq.native_dq_dry_run() -%}
  {%- set runnable = [] -%}
  {%- for s in statements if not s.startswith('--') -%}{% do runnable.append(s) %}{%- endfor -%}
  {%- if dry -%}
    {% do print('-- native_dq ' ~ title ~ ' (' ~ native_dq.native_dq_platform() ~ ', dry run, '
                ~ runnable | length ~ ' statements)') %}
    {%- for s in statements -%}
      {%- if s.startswith('--') -%}
        {% do print(s) %}
      {%- else -%}
        {% do print(s ~ ';') %}
        {% do print('') %}
      {%- endif -%}
    {%- endfor -%}
  {%- else -%}
    {%- for s in runnable -%}
      {% do log('native_dq: ' ~ s.split('\n')[0], info=true) %}
      {% do run_query(s) %}
    {%- endfor -%}
    {% do log('native_dq ' ~ title ~ ': ran ' ~ runnable | length ~ ' statements', info=true) %}
  {%- endif -%}
{% endmacro %}
