"""The rules find the planted errors in the synthetic data, and the Power BI views add up."""
import duckdb

from conftest import PROJECT, run_dbt

# Each planted error in integration_tests/seeds, and the count the rule should report.
EXPECTED = {
    "customers_customer_id_unique": (0, "pass"),
    "customers_email_not_null": (1, "pass"),        # one missing email is within threshold 1
    "customers_country_accepted": (1, "fail"),      # BR
    "orders_order_id_unique": (1, "fail"),          # 1006 twice
    "orders_customer_id_not_null": (1, "fail"),     # 1004
    "orders_status_accepted": (1, "fail"),          # LOST
    "orders_amount_range": (1, "fail"),             # -15.00
    "orders_ship_after_order": (1, "fail"),         # 1008 shipped before ordered
    "orders_cancelled_have_no_amount": (1, "fail"), # 1007
    "raw_customers_min_rows": (5, "pass"),
}


def test_rules_find_exactly_the_planted_errors(project):
    out = run_dbt(["run-operation", "native_dq_local_evaluate"], vars={"native_dq_platform": "local"}).stdout
    got = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[0] == "native_dq_local":
            got[parts[1]] = (int(parts[2]), parts[3])
    assert got == EXPECTED
    assert "native_dq_local raw_customers_fresh skipped" in out


def query(sql):
    con = duckdb.connect(str(PROJECT / "native_dq_dev.duckdb"), read_only=True)
    try:
        return con.sql(sql).fetchall()
    finally:
        con.close()


def test_rule_catalog_lists_every_rule(project):
    rows = query("select rule_id, result_name, status from analytics.dq_rule_catalog order by rule_id")
    assert len(rows) == 12
    assert ("orders_legacy_discount", "DQ_ORDERS_LEGACY_DISCOUNT", "retired") in rows


def test_latest_shows_fails_and_coverage_gaps(project):
    rows = dict(query("select rule_id, status from analytics.dq_latest"))
    assert "orders_legacy_discount" not in rows  # retired rules leave the scorecard
    assert rows["customers_customer_id_unique"] == "no result"
    assert rows["raw_customers_fresh"] == "no result"
    assert rows["orders_status_accepted"] == "fail"
    assert rows["orders_amount_range"] == "pass"
    assert sorted(rows.values()).count("fail") == 5


def test_daily_scores_trend(project):
    rows = query("""
        select measured_date, sum(checks_passed), sum(checks_run)
        from analytics.dq_daily_scores group by 1 order by 1""")
    assert [r[1] for r in rows] == [8, 7, 7, 6, 4]
    assert all(r[2] == 9 for r in rows)
    rate = query("select pass_rate from analytics.dq_daily_scores "
                 "where rule_id = 'orders_status_accepted' order by measured_date")
    assert [r[0] for r in rate] == [1.0, 1.0, 0.0, 0.0, 0.0]
