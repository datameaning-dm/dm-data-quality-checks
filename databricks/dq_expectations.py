"""Apply native_dq rules in a Databricks Python pipeline (Lakeflow Spark Declarative Pipelines).

`dbt run-operation native_dq_deploy` writes each table's rules to the rules table
(default <catalog>.dq_ops.dq_rules, columns name, constraint, tag, action, ...). This helper reads them
and applies them with the documented dp.expect_all* decorators, so rules stay in one YAML file in git.

    from pyspark import pipelines as dp
    from dq_expectations import expectations

    @dp.table
    @expectations(spark, "analytics_prod.dq_ops.dq_rules", "sales.orders")
    def orders():
        return spark.readStream.table("analytics_prod.landing.raw_orders")

Rules with action warn, drop and fail are applied. check_constraint rules are enforced by Delta itself.
Docs: https://docs.databricks.com/aws/en/ldp/expectation-patterns
      https://docs.databricks.com/aws/en/ldp/expectations
Not yet run in a live Databricks workspace.
"""
from pyspark import pipelines as dp
from pyspark.sql.functions import col


def load_rules(spark, rules_table, tag):
    """{action: {name: constraint}} for one table (tag = 'schema.table', lower case)."""
    rows = spark.read.table(rules_table).filter(col("tag") == tag.lower()).collect()
    rules = {"warn": {}, "drop": {}, "fail": {}}
    for row in rows:
        if row["action"] in rules:
            rules[row["action"]][row["name"]] = row["constraint"]
    return rules


def expectations(spark, rules_table, tag):
    """Decorator applying every warn, drop and fail rule for the table."""
    rules = load_rules(spark, rules_table, tag)

    def wrap(fn):
        if rules["fail"]:
            fn = dp.expect_all_or_fail(rules["fail"])(fn)
        if rules["drop"]:
            fn = dp.expect_all_or_drop(rules["drop"])(fn)
        if rules["warn"]:
            fn = dp.expect_all(rules["warn"])(fn)
        return fn

    return wrap
