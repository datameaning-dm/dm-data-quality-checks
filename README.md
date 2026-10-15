# native_dq: data quality rules as code, run natively in Snowflake and Databricks

> **Private draft.** Not published yet. Making it public is Data Meaning's decision.

> **Tested on Snowflake Enterprise Edition, 2026-10-15.** Every rule type deployed, and each check
> found exactly the errors planted in the sample data. See [Tested on Snowflake](#tested-on-snowflake).
> **Databricks: not yet tested live.** The Databricks SQL follows the vendor docs listed below and
> passes the local tests on DuckDB. Test in a development workspace first.

## What it is

A dbt package. You write data quality rules in YAML, next to your models.
The package turns each rule into the platform's own data quality feature:

- **Snowflake:** a data metric function (DMF) attached to the table, with an expectation.
  Snowflake runs it on a schedule and records pass or fail.
- **Databricks:** an expectation in a Lakeflow pipeline (formerly Delta Live Tables), or a Delta
  `CHECK` constraint.

No separate data quality tool and no separate jobs. The checks run inside the platform.

It also gives you:

- an alert that emails the data steward when a check fails (Snowflake),
- views for a Power BI report: scores, trends and coverage per rule, table and column,
- one rules file deployed unchanged to dev, test and prod.

## Quickstart

1. Add the package to your dbt project's `packages.yml`, then run `dbt deps`:

   ```yaml
   packages:
     - local: ../dm-data-quality-checks   # or a git URL once published
   ```

2. Declare rules under `meta.native_dq` on a model, seed, snapshot or source table:

   ```yaml
   models:
     - name: orders
       config:
         meta:
           native_dq:
             steward: steward.sales@example.com
             rules:
               - id: orders_customer_id_not_null
                 type: not_null
                 column: customer_id
                 severity: critical
               - id: orders_status_accepted
                 type: accepted_values
                 column: status
                 values: [OPEN, SHIPPED, CLOSED, CANCELLED]
   ```

   A full example is in [`integration_tests/models/rules.yml`](integration_tests/models/rules.yml).

3. Check the rules, then look at the SQL. Nothing runs yet (dry run is the default):

   ```bash
   dbt run-operation native_dq_validate
   dbt run-operation native_dq_deploy
   ```

4. Deploy for real:

   ```bash
   dbt run-operation native_dq_deploy --vars '{native_dq_dry_run: false}'
   ```

5. Keep the checks attached when dbt rebuilds a table. Add the post-hook in `dbt_project.yml`:

   ```yaml
   models:
     my_project:
       +post-hook: "{{ native_dq.native_dq_apply() }}"
   ```

   On Snowflake, `CREATE OR REPLACE` removes every DMF from the table. dbt rebuilds tables that way.
   The post-hook puts the checks back right after each build.

## Rule types and what they become

| Rule `type` | Snowflake | Databricks |
|---|---|---|
| `not_null` | `SNOWFLAKE.CORE.NULL_COUNT ON (col)` | `col IS NOT NULL` |
| `unique` | `SNOWFLAKE.CORE.DUPLICATE_COUNT ON (col)` | not row-level: skipped |
| `accepted_values` | `SNOWFLAKE.CORE.ACCEPTED_VALUES ON (col, col -> col IN (...))` | `col IN (...)` |
| `range` (`min`, `max`) | custom DMF counting rows outside the range | `col >= min AND col <= max` |
| `expression` (`expression`, `columns`) | custom DMF counting rows where the expression is false | the expression |
| `custom` (`sql`, `columns`) | custom DMF running your failing-row query on `T` | not supported: skipped |
| `freshness` (`max_age_seconds`) | `SNOWFLAKE.CORE.FRESHNESS ON (col)` | not row-level: skipped |
| `row_count_min` (`min_rows`) | `SNOWFLAKE.CORE.ROW_COUNT ON ()` | not row-level: skipped |

Every rule also takes `threshold` (failing rows allowed, default 0), `severity`
(critical, high, medium, low), `dimension` (completeness, uniqueness, validity, consistency, accuracy,
timeliness), `steward`, `status` (`active` or `retired`), `name` and `description`.
On Databricks, `databricks_action` is `warn` (default), `drop`, `fail` or `check_constraint`.

### Snowflake details

- Each rule gets an expectation named `DQ_<RULE_ID>`, for example
  `EXPECTATION DQ_ORDERS_CUSTOMER_ID_NOT_NULL (VALUE <= 0)`. `VALUE` is the DMF's result.
- `range`, `expression` and `custom` create a custom DMF in `<database>.DATA_QUALITY`. Its signature
  needs each column's type, so declare `data_type` under `columns:` in the YAML.
- The table's schedule is set with `ALTER TABLE ... SET DATA_METRIC_SCHEDULE`. Default
  `TRIGGER_ON_CHANGES`: the checks run when the data changes. You can use `'60 MINUTE'` or
  `'USING CRON 0 7 * * * UTC'` per table (`schedule:` under `native_dq`).
- `EXECUTE AS ROLE` comes before `EXPECTATION`. Set the role with `native_dq_execute_as_role`.
- Each deploy detaches a rule's DMF if attached, then adds it again. So deploys can be repeated, and
  a changed rule replaces the old one. A retired rule is detached and its custom DMF dropped.
- Grants: [`alerting/snowflake_grants.sql`](alerting/snowflake_grants.sql).

### Databricks details

- Rules go into a rules table, `<catalog>.dq_ops.dq_rules` (`name`, `constraint`, `tag`, plus
  `action`, `severity`, `steward`). This is Databricks' documented pattern for reusable expectations.
- **Python pipelines** read that table with [`databricks/dq_expectations.py`](databricks/dq_expectations.py),
  which applies `dp.expect_all`, `dp.expect_all_or_drop` and `dp.expect_all_or_fail`.
- **SQL pipelines** cannot load expectations from a table. Run
  `dbt run-operation native_dq_pipeline_sql` and paste the `CONSTRAINT ... EXPECT (...)` lines into the
  table's `CREATE OR REFRESH STREAMING TABLE` or `MATERIALIZED VIEW` statement.
- `databricks_action: check_constraint` adds a Delta `CHECK` constraint instead. It rejects any write
  with a bad row, on any table, not only pipeline tables.

## Rules as code across dev, test and prod

The rules never name a database or catalog. dbt's target supplies it. The same YAML deploys to
`ANALYTICS_DEV`, `ANALYTICS_TEST` and `ANALYTICS_PROD`:

```bash
dbt run-operation native_dq_deploy --target test --vars '{native_dq_dry_run: false}'
dbt run-operation native_dq_deploy --target prod --vars '{native_dq_dry_run: false}'
```

Example profiles with three targets: [`integration_tests/profiles.example.yml`](integration_tests/profiles.example.yml).
Keep the rules in GitHub. Review rule changes in pull requests. Run `native_dq_validate` in CI.
Deploy to prod from the main branch only.

## Alert the data steward (Snowflake)

[`alerting/snowflake_steward_alert.sql`](alerting/snowflake_steward_alert.sql) sets up:

1. an email notification integration listing the stewards,
2. a procedure that sends each steward one email with their failed rules,
3. a Snowflake alert that runs every 15 minutes and calls the procedure when there are new failures.

Stewards must be Snowflake users in the account with a verified email address. That is a Snowflake rule.

For Databricks, [`alerting/databricks_failures.sql`](alerting/databricks_failures.sql) is a query for a
Databricks SQL alert with email destinations.

## Power BI report

The package builds four views. Point Power BI at them:

| View | One row per | Use it for |
|---|---|---|
| `dq_rule_catalog` | rule | what is checked, who stewards it |
| `dq_results` | rule per run | every pass and fail |
| `dq_latest` | active rule | the scorecard: pass, fail, or **no result** (a coverage gap) |
| `dq_daily_scores` | rule per day | trends: pass rate by table, column or dimension |

On Snowflake, `dq_results` reads `SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_EXPECTATION_STATUS`.
On Databricks, it reads the pipeline event log. Set `native_dq_databricks_event_log`, for example
`"event_log('<pipeline id>')"` or your published event log table.

## Tests (no Snowflake or Databricks needed)

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest -q tests
```

The tests run dbt against DuckDB, on synthetic data. They check that:

- the generated Snowflake and Databricks SQL matches reviewed snapshots in `tests/snapshots/`,
- each rule finds exactly the errors planted in the sample data (`native_dq_local_evaluate`),
- the Power BI views give the expected scores and trends,
- invalid rules are refused with a clear message.

After an intended SQL change, run with `UPDATE_SNAPSHOTS=1` and review the diff.

## Limitations

- **Databricks is not yet tested live**, and parts of the Snowflake setup are not either. See the lists below.
- Snowflake data quality monitoring needs Enterprise Edition or higher.
- Snowflake allows one system DMF of a kind per column. Two `accepted_values` rules on one column are
  refused: combine them. Redeploying a rule also replaces a hand-made DMF of the same kind on that column.
- Snowflake `FRESHNESS` takes DATE, TIMESTAMP_LTZ or TIMESTAMP_TZ, not TIMESTAMP_NTZ. The validator
  refuses `freshness` on a column declared TIMESTAMP_NTZ. The declared type must match the real column:
  if the YAML says TIMESTAMP_LTZ but the table holds TIMESTAMP_NTZ, Snowflake fails the deploy with
  "Function 'FRESHNESS$V1' does not exist or not authorized".
- Custom DMF bodies must be deterministic. Snowflake refuses `CURRENT_TIMESTAMP` and similar there.
- `TRIGGER_ON_CHANGES` works only on some kinds of tables. Use a minute or cron schedule for views.
- Databricks expectations run only on tables a Lakeflow pipeline builds. `unique`, `freshness`,
  `row_count_min` and `custom` have no Databricks equivalent here.
- Removing a rule from the YAML does not remove its check. Set `status: retired` first, deploy, then delete.
- Rule text goes into DDL, so names must be plain identifiers, and `;`, `$$`, `--` and backslashes are refused.

## Tested on Snowflake

On 2026-10-15, on Snowflake Enterprise Edition (AWS us-east-1), with dbt-core 1.12 and dbt-snowflake
1.12, using the `integration_tests` project and its sample data, deployed by a sandbox role with key-pair sign-in:

- `dbt run` built both models, and the post-hook attached every rule's DMF after dbt replaced each table.
  A second `dbt run` replaced the tables again, and every check was back afterwards.
- `dbt run-operation native_dq_deploy` ran all 31 statements, including the source table's rules, and
  ran again cleanly on top of itself.
- Custom DMFs were created with `NUMBER(12,2)` and `DATE` signatures; the retired rule's DMF was dropped
  by its signature; the `EXECUTE IMMEDIATE ... EXCEPTION WHEN OTHER THEN NULL` detach step ran through
  the dbt-snowflake connector.
- Every attachment showed `STARTED`, with the table's schedule.
- `SYSTEM$EVALUATE_DATA_QUALITY_EXPECTATIONS` returned, for all 10 active rules, exactly the counts and
  the pass or fail the local tests expect. `freshness` correctly failed on the sample data, which is
  weeks old.

## Needs a live account to confirm

- Snowflake: the `dq_results` view and the three views built on it. The test role did not hold the
  `SNOWFLAKE.DATA_QUALITY_MONITORING_VIEWER` application role that the grants file lists, so the
  view could not read `DATA_QUALITY_MONITORING_EXPECTATION_STATUS`.
- Snowflake alerting: `CALL SYSTEM$SEND_EMAIL` with bound variables inside the procedure; the 10-minute
  margin for results to land; `GRANT USAGE ON ALL FUNCTIONS` covering DMFs.
- Databricks: the backslash-escaped quotes in the rules table insert; the event log column paths and
  the join from event log expectation names to `dq_rule_catalog`; `databricks/dq_expectations.py` in a pipeline.
- Power BI: whether a reporting role needs `SELECT` on every checked table to read results through the view.

## Docs this follows

Checked 2026-10-12.

Snowflake:
- [CREATE DATA METRIC FUNCTION](https://docs.snowflake.com/en/sql-reference/sql/create-data-metric-function)
- [ALTER TABLE (DMF and schedule clauses)](https://docs.snowflake.com/en/sql-reference/sql/alter-table)
- [Expectations](https://docs.snowflake.com/en/user-guide/data-quality-expectations)
- [Working with DMFs and schedules](https://docs.snowflake.com/en/user-guide/data-quality-working)
- [System DMFs](https://docs.snowflake.com/en/user-guide/data-quality-system-dmfs),
  [ACCEPTED_VALUES](https://docs.snowflake.com/en/sql-reference/functions/dmf_accepted_values),
  [FRESHNESS](https://docs.snowflake.com/en/sql-reference/functions/dmf_freshness)
- [Custom DMFs](https://docs.snowflake.com/en/user-guide/data-quality-custom-dmfs)
- [Access control](https://docs.snowflake.com/en/user-guide/data-quality-access-control)
- [DATA_QUALITY_MONITORING_EXPECTATION_STATUS](https://docs.snowflake.com/en/sql-reference/local/data_quality_monitoring_expectation_status)
- [Email notifications](https://docs.snowflake.com/en/user-guide/notifications/email-notifications),
  [SYSTEM$SEND_EMAIL](https://docs.snowflake.com/en/sql-reference/stored-procedures/system_send_email)
- [CREATE ALERT](https://docs.snowflake.com/en/sql-reference/sql/create-alert),
  [Alerts](https://docs.snowflake.com/en/user-guide/alerts)
- [Snowflake Scripting exceptions](https://docs.snowflake.com/en/developer-guide/snowflake-scripting/exceptions)

Databricks:
- [Expectations](https://docs.databricks.com/aws/en/ldp/expectations)
- [Expectation patterns (rules table)](https://docs.databricks.com/aws/en/ldp/expectation-patterns)
- [Event log](https://docs.databricks.com/aws/en/ldp/monitor-event-logs)
- [Constraints (CHECK, NOT NULL)](https://docs.databricks.com/aws/en/tables/constraints),
  [DROP CONSTRAINT](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-syntax-ddl-alter-table-drop-constraint)
- [SQL alerts](https://docs.databricks.com/aws/en/sql/user/alerts/)

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
Copyright 2026 Data Meaning.
