"""Invalid rules are refused with a message that says what to fix."""
import pytest

from conftest import run_dbt

BAD_MODEL = "select 1 as x, 2 as y, current_timestamp as loaded_at"


def rules_yaml(rules, columns=""):
    body = "\n".join("            " + line for line in rules.strip().splitlines())
    return f"""version: 2
models:
  - name: bad_rules
    config:
      meta:
        native_dq:
          steward: steward.test@example.com
          rules:
{body}
{columns}"""


CASES = {
    "bad id": ("- {id: Bad-Id, type: not_null, column: x}", "", "id must be lower-case"),
    "unknown type": ("- {id: r1, type: no_such_check, column: x}", "", "type must be one of"),
    "unknown key": ("- {id: r1, type: not_null, column: x, colum: y}", "", "unknown key 'colum'"),
    "missing column": ("- {id: r1, type: not_null}", "", "needs column"),
    "duplicate id": ("- {id: orders_order_id_unique, type: not_null, column: x}", "", "Rule ids must be unique"),
    "semicolon": ("- {id: r1, type: expression, columns: [x], expression: 'x > 0; drop table t'}", "", "may not contain ';'"),
    "quote in value": ("- {id: r1, type: accepted_values, column: x, values: [\"a'b\"]}", "", "may not contain a quote"),
    "bad steward": ("- {id: r1, type: not_null, column: x, steward: nobody}", "", "steward email"),
    "two dmfs one column": (
        "- {id: r1, type: accepted_values, column: x, values: [a]}\n- {id: r2, type: accepted_values, column: x, values: [b]}",
        "", "one data metric function of a kind per column"),
    "freshness on ntz": (
        "- {id: r1, type: freshness, column: loaded_at, max_age_seconds: 60}",
        "    columns:\n      - name: loaded_at\n        data_type: TIMESTAMP_NTZ",
        "Snowflake FRESHNESS does not accept TIMESTAMP_NTZ"),
    "custom needs types": ("- {id: r1, type: range, column: x, min: 0}", "", "needs the data_type of column X"),
    "negative threshold": ("- {id: r1, type: not_null, column: x, threshold: -1}", "", "threshold"),
}


@pytest.mark.parametrize("name", list(CASES))
def test_invalid_rule_is_refused(scratch_project, name):
    rules, columns, message = CASES[name]
    (scratch_project / "models" / "bad_rules.sql").write_text(BAD_MODEL)
    (scratch_project / "models" / "bad_rules.yml").write_text(rules_yaml(rules, columns))
    proc = run_dbt(["run-operation", "native_dq_validate"], cwd=scratch_project,
                   vars={"native_dq_platform": "snowflake"}, check=False)
    assert proc.returncode != 0, f"{name}: dbt accepted an invalid rule"
    assert message in proc.stdout + proc.stderr


def test_valid_extra_rule_is_accepted(scratch_project):
    (scratch_project / "models" / "bad_rules.sql").write_text(BAD_MODEL)
    (scratch_project / "models" / "bad_rules.yml").write_text(rules_yaml("- {id: r1, type: not_null, column: x}"))
    out = run_dbt(["run-operation", "native_dq_validate"], cwd=scratch_project,
                  vars={"native_dq_platform": "snowflake"}).stdout
    assert "13 rule(s) on 4 table(s) are valid" in out
