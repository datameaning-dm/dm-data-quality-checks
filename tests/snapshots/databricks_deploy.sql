-- native_dq deploy (databricks, dry run, 9 statements)
CREATE SCHEMA IF NOT EXISTS native_dq_dev.dq_ops;

CREATE TABLE IF NOT EXISTS native_dq_dev.dq_ops.dq_rules (
  name STRING,
  `constraint` STRING,
  tag STRING,
  action STRING,
  rule_id STRING,
  dimension STRING,
  severity STRING,
  threshold INT,
  steward STRING
);

-- model.native_dq_integration_tests.customers -> native_dq_dev.analytics.customers
-- rule customers_customer_id_unique skipped: unique is not a row-level expectation on Databricks
ALTER TABLE native_dq_dev.analytics.customers DROP CONSTRAINT IF EXISTS dq_customers_country_accepted;

ALTER TABLE native_dq_dev.analytics.customers ADD CONSTRAINT dq_customers_country_accepted CHECK (country IN ('US', 'CA', 'MX'));

DELETE FROM native_dq_dev.dq_ops.dq_rules WHERE tag = 'analytics.customers';

INSERT INTO native_dq_dev.dq_ops.dq_rules VALUES
  ('dq_customers_email_not_null', 'email IS NOT NULL', 'analytics.customers', 'warn', 'customers_email_not_null', 'completeness', 'medium', 1, 'steward.crm@example.com'),
  ('dq_customers_country_accepted', 'country IN (\'US\', \'CA\', \'MX\')', 'analytics.customers', 'check_constraint', 'customers_country_accepted', 'validity', 'medium', 0, 'steward.crm@example.com');

-- model.native_dq_integration_tests.orders -> native_dq_dev.analytics.orders
-- rule orders_order_id_unique skipped: unique is not a row-level expectation on Databricks
-- rule orders_cancelled_have_no_amount skipped: custom is not a row-level expectation on Databricks
DELETE FROM native_dq_dev.dq_ops.dq_rules WHERE tag = 'analytics.orders';

INSERT INTO native_dq_dev.dq_ops.dq_rules VALUES
  ('dq_orders_customer_id_not_null', 'customer_id IS NOT NULL', 'analytics.orders', 'warn', 'orders_customer_id_not_null', 'completeness', 'critical', 0, 'steward.sales@example.com'),
  ('dq_orders_status_accepted', 'status IN (\'OPEN\', \'SHIPPED\', \'CLOSED\', \'CANCELLED\')', 'analytics.orders', 'warn', 'orders_status_accepted', 'validity', 'high', 0, 'steward.sales@example.com'),
  ('dq_orders_amount_range', 'amount >= 0 AND amount <= 100000', 'analytics.orders', 'drop', 'orders_amount_range', 'validity', 'high', 0, 'steward.sales@example.com'),
  ('dq_orders_ship_after_order', 'ship_date IS NULL OR ship_date >= order_date', 'analytics.orders', 'warn', 'orders_ship_after_order', 'consistency', 'medium', 0, 'steward.sales@example.com');

-- source.native_dq_integration_tests.landing.raw_customers -> native_dq_dev.analytics.raw_customers
-- rule raw_customers_min_rows skipped: row_count_min is not a row-level expectation on Databricks
-- rule raw_customers_fresh skipped: freshness is not a row-level expectation on Databricks
DELETE FROM native_dq_dev.dq_ops.dq_rules WHERE tag = 'analytics.raw_customers';

