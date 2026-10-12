{#-
  Rules are declared in a model's, seed's, snapshot's or source table's YAML under meta.native_dq:

    meta:
      native_dq:
        steward: steward.sales@example.com   # default for every rule below
        rules:
          - id: orders_customer_not_null
            type: not_null
            column: customer_id

  These macros find every declaration, fill defaults, and refuse anything invalid.
-#}

{% macro native_dq_rule_types() %}
  {{ return({
      'not_null':        {'dimension': 'completeness', 'needs_column': true},
      'unique':          {'dimension': 'uniqueness',   'needs_column': true},
      'accepted_values': {'dimension': 'validity',     'needs_column': true},
      'range':           {'dimension': 'validity',     'needs_column': true},
      'freshness':       {'dimension': 'timeliness',   'needs_column': true},
      'row_count_min':   {'dimension': 'completeness', 'needs_column': false},
      'expression':      {'dimension': 'validity',     'needs_column': false},
      'custom':          {'dimension': 'validity',     'needs_column': false},
  }) }}
{% endmacro %}

{#- meta can sit at the top level (older dbt) or under config (dbt 1.10+). -#}
{% macro native_dq_node_meta(node) %}
  {%- set meta = {} -%}
  {%- do meta.update(node.get('meta') or {}) -%}
  {%- set config = node.get('config') or {} -%}
  {%- do meta.update(config.get('meta') or {}) -%}
  {{ return(meta.get('native_dq')) }}
{% endmacro %}

{#- The table a node's rules attach to, plus its declared column types. -#}
{% macro native_dq_node_target(node) %}
  {%- set columns = {} -%}
  {%- for name, col in (node.get('columns') or {}).items() -%}
    {%- do columns.update({name | upper: col.get('data_type')}) -%}
  {%- endfor -%}
  {%- set config = node.get('config') or {} -%}
  {%- set materialized = config.get('materialized') -%}
  {%- set kind = 'VIEW' if materialized in ['view', 'ephemeral'] else 'TABLE' -%}
  {%- set identifier = node.get('alias') or node.get('identifier') or node.get('name') -%}
  {{ return({
      'unique_id': node.get('unique_id'),
      'node_name': node.get('name'),
      'kind': kind,
      'database': node.get('database'),
      'schema': node.get('schema'),
      'identifier': identifier,
      'columns': columns,
  }) }}
{% endmacro %}

{% macro native_dq_fail(rule_id, where, message) %}
  {{ exceptions.raise_compiler_error("native_dq: rule '" ~ rule_id ~ "' on " ~ where ~ ": " ~ message) }}
{% endmacro %}

{% macro native_dq_normalize_rule(rule, target, defaults) %}
  {%- set where = target.unique_id -%}
  {%- set types = native_dq.native_dq_rule_types() -%}
  {%- if rule is not mapping -%}
    {{ native_dq.native_dq_fail('?', where, 'each rule must be a mapping') }}
  {%- endif -%}

  {%- set rid = rule.get('id') -%}
  {%- if rid is not string or modules.re.match('^[a-z][a-z0-9_]{0,59}$', rid) is none -%}
    {{ native_dq.native_dq_fail(rid, where, 'id must be lower-case letters, digits and underscores, '
        ~ 'start with a letter, at most 60 characters') }}
  {%- endif -%}

  {%- set known = ['id', 'type', 'name', 'description', 'column', 'columns', 'values', 'min', 'max',
                   'max_age_seconds', 'min_rows', 'expression', 'sql', 'threshold', 'dimension',
                   'severity', 'steward', 'status', 'databricks_action'] -%}
  {%- for key in rule.keys() if key not in known -%}
    {{ native_dq.native_dq_fail(rid, where, "unknown key '" ~ key ~ "'") }}
  {%- endfor -%}

  {%- set rtype = rule.get('type') -%}
  {%- if rtype not in types -%}
    {{ native_dq.native_dq_fail(rid, where, "type must be one of " ~ (types.keys() | list | sort | join(', '))) }}
  {%- endif -%}

  {%- set column = rule.get('column') -%}
  {%- if types[rtype].needs_column -%}
    {%- if not native_dq.native_dq_is_identifier(column) -%}
      {{ native_dq.native_dq_fail(rid, where, 'needs column: a plain column name') }}
    {%- endif -%}
  {%- elif column is not none and not native_dq.native_dq_is_identifier(column) -%}
    {{ native_dq.native_dq_fail(rid, where, 'column must be a plain column name') }}
  {%- endif -%}

  {#- Columns the check reads. Custom Snowflake functions need them (with types) in their signature. -#}
  {%- set columns = rule.get('columns') or ([column] if column else []) -%}
  {%- if columns is string or columns is mapping -%}
    {{ native_dq.native_dq_fail(rid, where, 'columns must be a list of column names') }}
  {%- endif -%}
  {%- for c in columns if not native_dq.native_dq_is_identifier(c) -%}
    {{ native_dq.native_dq_fail(rid, where, "column '" ~ c ~ "' is not a plain column name") }}
  {%- endfor -%}

  {%- set threshold = rule.get('threshold', 0) -%}
  {%- if threshold is not number or threshold < 0 or threshold != threshold | int -%}
    {{ native_dq.native_dq_fail(rid, where, 'threshold (failing rows allowed) must be a whole number >= 0') }}
  {%- endif -%}

  {%- set out = {
      'id': rid,
      'type': rtype,
      'name': rule.get('name') or rid | replace('_', ' '),
      'description': rule.get('description') or '',
      'column': column | upper if column else none,
      'columns': columns | map('upper') | list,
      'threshold': threshold | int,
      'expectation_name': (native_dq.native_dq_prefix() ~ rid) | upper,
  } -%}

  {%- if rtype == 'accepted_values' -%}
    {%- set values = rule.get('values') -%}
    {%- if values is string or values is not iterable or values | length == 0 -%}
      {{ native_dq.native_dq_fail(rid, where, 'accepted_values needs a non-empty values list') }}
    {%- endif -%}
    {%- set clean = [] -%}
    {%- for v in values -%}
      {%- set v = v | string -%}
      {%- if "'" in v or '\\' in v or ';' in v -%}
        {{ native_dq.native_dq_fail(rid, where, "value " ~ v ~ " may not contain a quote, backslash or ';'") }}
      {%- endif -%}
      {%- do clean.append(v) -%}
    {%- endfor -%}
    {%- do out.update({'values': clean}) -%}

  {%- elif rtype == 'range' -%}
    {%- set lo = rule.get('min') -%}
    {%- set hi = rule.get('max') -%}
    {%- if lo is none and hi is none -%}
      {{ native_dq.native_dq_fail(rid, where, 'range needs min, max or both') }}
    {%- endif -%}
    {%- for b in [lo, hi] if b is not none and b is not number -%}
      {{ native_dq.native_dq_fail(rid, where, 'range min and max must be numbers') }}
    {%- endfor -%}
    {%- do out.update({'min': lo, 'max': hi}) -%}

  {%- elif rtype == 'freshness' -%}
    {%- set age = rule.get('max_age_seconds') -%}
    {%- if age is not number or age <= 0 -%}
      {{ native_dq.native_dq_fail(rid, where, 'freshness needs max_age_seconds > 0') }}
    {%- endif -%}
    {#- Snowflake's FRESHNESS takes DATE, TIMESTAMP_LTZ or TIMESTAMP_TZ only. TIMESTAMP and DATETIME
        default to TIMESTAMP_NTZ, which it refuses with a misleading "does not exist" error. -#}
    {%- set dtype = (target.columns.get(column | upper) or '') | upper | replace(' ', '') -%}
    {%- if dtype in ['TIMESTAMP', 'DATETIME', 'TIMESTAMP_NTZ'] or dtype.startswith('TIMESTAMP_NTZ')
          or dtype.startswith('TIMESTAMP(') or dtype.startswith('DATETIME(') -%}
      {{ native_dq.native_dq_fail(rid, where, 'freshness needs a DATE, TIMESTAMP_LTZ or TIMESTAMP_TZ column; '
          ~ column ~ ' is declared ' ~ dtype ~ '. Snowflake FRESHNESS does not accept TIMESTAMP_NTZ.') }}
    {%- endif -%}
    {%- do out.update({'max_age_seconds': age | int}) -%}

  {%- elif rtype == 'row_count_min' -%}
    {%- set n = rule.get('min_rows') -%}
    {%- if n is not number or n < 0 -%}
      {{ native_dq.native_dq_fail(rid, where, 'row_count_min needs min_rows >= 0') }}
    {%- endif -%}
    {%- do out.update({'min_rows': n | int}) -%}

  {%- elif rtype == 'expression' -%}
    {{ native_dq.native_dq_check_sql_text(rule.get('expression'), 'an expression (true for a valid row)', rid) }}
    {%- if columns | length == 0 -%}
      {{ native_dq.native_dq_fail(rid, where, 'expression needs columns: the columns the expression reads') }}
    {%- endif -%}
    {%- do out.update({'expression': rule.get('expression') | trim}) -%}

  {%- elif rtype == 'custom' -%}
    {{ native_dq.native_dq_check_sql_text(rule.get('sql'), 'sql (a query counting failing rows of T)', rid) }}
    {%- if columns | length == 0 -%}
      {{ native_dq.native_dq_fail(rid, where, 'custom needs columns: the columns the query reads from T') }}
    {%- endif -%}
    {%- do out.update({'sql': rule.get('sql') | trim}) -%}
  {%- endif -%}

  {%- set dims = ['completeness', 'uniqueness', 'validity', 'consistency', 'accuracy', 'timeliness'] -%}
  {%- set dimension = (rule.get('dimension') or types[rtype].dimension) | lower -%}
  {%- if dimension not in dims -%}
    {{ native_dq.native_dq_fail(rid, where, 'dimension must be one of ' ~ dims | join(', ')) }}
  {%- endif -%}

  {%- set severity = (rule.get('severity') or defaults.get('severity') or 'medium') | lower -%}
  {%- if severity not in ['critical', 'high', 'medium', 'low'] -%}
    {{ native_dq.native_dq_fail(rid, where, 'severity must be critical, high, medium or low') }}
  {%- endif -%}

  {%- set steward = rule.get('steward') or defaults.get('steward') -%}
  {%- if steward is not string or modules.re.match('^[^@\\s\'";,]+@[^@\\s\'";,]+\\.[^@\\s\'";,]+$', steward) is none -%}
    {{ native_dq.native_dq_fail(rid, where, 'needs a steward email address (on the rule or under native_dq)') }}
  {%- endif -%}

  {%- set status = (rule.get('status') or 'active') | lower -%}
  {%- if status not in ['active', 'retired'] -%}
    {{ native_dq.native_dq_fail(rid, where, 'status must be active or retired') }}
  {%- endif -%}

  {%- set action = (rule.get('databricks_action') or defaults.get('databricks_action') or 'warn') | lower -%}
  {%- if action not in ['warn', 'drop', 'fail', 'check_constraint'] -%}
    {{ native_dq.native_dq_fail(rid, where, 'databricks_action must be warn, drop, fail or check_constraint') }}
  {%- endif -%}

  {%- for text in [out.name, out.description] if "'" in text or '\\' in text -%}
    {{ native_dq.native_dq_fail(rid, where, 'name and description may not contain a quote or backslash') }}
  {%- endfor -%}

  {%- do out.update({'dimension': dimension, 'severity': severity, 'steward': steward | lower,
                     'status': status, 'databricks_action': action}) -%}
  {{ return(out) }}
{% endmacro %}

{#- One node's declaration -> {target, rules}. Returns none when the node declares nothing. -#}
{% macro native_dq_node_rules(node) %}
  {%- set decl = native_dq.native_dq_node_meta(node) -%}
  {%- if not decl -%}{{ return(none) }}{%- endif -%}
  {%- set target = native_dq.native_dq_node_target(node) -%}
  {%- if decl is not mapping -%}
    {{ exceptions.raise_compiler_error("native_dq: meta.native_dq on " ~ target.unique_id ~ " must be a mapping") }}
  {%- endif -%}
  {%- set defaults = {'steward': decl.get('steward'), 'severity': decl.get('severity'),
                      'databricks_action': decl.get('databricks_action')} -%}
  {%- set rules = [] -%}
  {%- for rule in decl.get('rules') or [] -%}
    {%- do rules.append(native_dq.native_dq_normalize_rule(rule, target, defaults)) -%}
  {%- endfor -%}
  {%- do target.update({'schedule': decl.get('schedule') or var('native_dq_schedule', 'TRIGGER_ON_CHANGES')}) -%}
  {{ return({'target': target, 'rules': rules}) }}
{% endmacro %}

{#- Every declaration in the project, sorted, with project-wide checks. -#}
{% macro native_dq_collect(select=none) %}
  {%- set found = [] -%}
  {%- if not execute -%}{{ return(found) }}{%- endif -%}
  {%- set nodes = [] -%}
  {%- for node in graph.nodes.values() if node.resource_type in ['model', 'seed', 'snapshot'] -%}
    {%- do nodes.append(node) -%}
  {%- endfor -%}
  {%- for node in graph.sources.values() -%}{%- do nodes.append(node) -%}{%- endfor -%}

  {%- set selected = none -%}
  {%- if select -%}
    {%- set selected = (select.split(',') if select is string else select) | map('trim') | list -%}
  {%- endif -%}

  {%- for node in nodes | sort(attribute='unique_id') -%}
    {%- if selected is none or node.name in selected -%}
      {%- set entry = native_dq.native_dq_node_rules(node) -%}
      {%- if entry and entry.rules | length > 0 -%}{%- do found.append(entry) -%}{%- endif -%}
    {%- endif -%}
  {%- endfor -%}
  {%- do native_dq.native_dq_check_project(found) -%}
  {{ return(found) }}
{% endmacro %}

{#- Rule ids are unique across the project. On Snowflake, one system DMF of a kind per column. -#}
{% macro native_dq_check_project(entries) %}
  {%- set seen = {} -%}
  {%- for e in entries -%}
    {%- set kinds = {} -%}
    {%- for r in e.rules -%}
      {%- if r.id in seen -%}
        {{ exceptions.raise_compiler_error("native_dq: rule id '" ~ r.id ~ "' is used on both "
            ~ seen[r.id] ~ " and " ~ e.target.unique_id ~ ". Rule ids must be unique.") }}
      {%- endif -%}
      {%- do seen.update({r.id: e.target.unique_id}) -%}
      {%- set dmf = native_dq.native_dq_snowflake_system_dmf(r) -%}
      {%- if dmf and r.status == 'active' -%}
        {%- set key = dmf ~ '(' ~ (r.column or '') ~ ')' -%}
        {%- if key in kinds -%}
          {{ exceptions.raise_compiler_error("native_dq: rules '" ~ kinds[key] ~ "' and '" ~ r.id ~ "' on "
              ~ e.target.unique_id ~ " both use " ~ key ~ ". Snowflake allows one data metric function of "
              ~ "a kind per column: combine them into one rule.") }}
        {%- endif -%}
        {%- do kinds.update({key: r.id}) -%}
      {%- endif -%}
    {%- endfor -%}
  {%- endfor -%}
{% endmacro %}
