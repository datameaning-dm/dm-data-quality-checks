"""The SQL the package generates, compared with reviewed snapshots in tests/snapshots/."""
from conftest import match_snapshot, run_dbt


def test_snowflake_deploy_sql(project):
    out = run_dbt(["run-operation", "native_dq_deploy"], vars={"native_dq_platform": "snowflake"}).stdout
    match_snapshot("snowflake_deploy.sql", out)
    # Spot checks that do not depend on the snapshot.
    assert "EXECUTE AS ROLE DQ_RUNNER\n  EXPECTATION DQ_ORDERS_ORDER_ID_UNIQUE (VALUE <= 0)" in out
    assert "SNOWFLAKE.CORE.ROW_COUNT ON ()" in out
    assert "DROP FUNCTION IF EXISTS NATIVE_DQ_DEV.DATA_QUALITY.DQ_ORDERS_LEGACY_DISCOUNT(TABLE(NUMBER(12,2)))" in out
    # A retired rule is detached and never re-added.
    assert "ADD DATA METRIC FUNCTION NATIVE_DQ_DEV.DATA_QUALITY.DQ_ORDERS_LEGACY_DISCOUNT" not in out


def test_databricks_deploy_sql(project):
    out = run_dbt(["run-operation", "native_dq_deploy"], vars={"native_dq_platform": "databricks"}).stdout
    match_snapshot("databricks_deploy.sql", out)
    assert "ADD CONSTRAINT dq_customers_country_accepted CHECK (country IN ('US', 'CA', 'MX'))" in out
    assert "-- rule orders_order_id_unique skipped" in out


def test_databricks_pipeline_sql(project):
    out = run_dbt(["run-operation", "native_dq_pipeline_sql"], vars={"native_dq_platform": "databricks"}).stdout
    match_snapshot("databricks_pipeline.sql", out)
    assert "CONSTRAINT dq_orders_amount_range EXPECT (amount >= 0 AND amount <= 100000) ON VIOLATION DROP ROW" in out
    # check_constraint rules are enforced by Delta, not by the pipeline.
    assert "dq_customers_country_accepted" not in out


def test_select_limits_deploy_to_one_table(project):
    out = run_dbt(["run-operation", "native_dq_deploy", "--args", "{select: customers}"],
                  vars={"native_dq_platform": "snowflake"}).stdout
    assert "ANALYTICS.CUSTOMERS" in out and "ANALYTICS.ORDERS" not in out


def test_post_hook_reattaches_checks_after_build(project):
    out = run_dbt(["run", "--select", "orders"], vars={"native_dq_platform": "snowflake"}).stdout
    assert out.startswith("-- native_dq apply orders (snowflake, dry run, 19 statements)")
    assert "ALTER TABLE NATIVE_DQ_DEV.ANALYTICS.ORDERS SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';" in out
    assert "CUSTOMERS" not in out


def test_validate_counts_rules(project):
    out = run_dbt(["run-operation", "native_dq_validate"], vars={"native_dq_platform": "snowflake"}).stdout
    assert "native_dq: 12 rule(s) on 3 table(s) are valid for snowflake" in out
