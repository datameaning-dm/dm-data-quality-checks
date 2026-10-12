-- native_dq: expectations for Databricks SQL pipelines. Paste each block into the column list
-- of that table's CREATE OR REFRESH STREAMING TABLE / MATERIALIZED VIEW statement.

-- native_dq_dev.analytics.customers
CONSTRAINT dq_customers_email_not_null EXPECT (email IS NOT NULL)

-- native_dq_dev.analytics.orders
CONSTRAINT dq_orders_customer_id_not_null EXPECT (customer_id IS NOT NULL),
CONSTRAINT dq_orders_status_accepted EXPECT (status IN ('OPEN', 'SHIPPED', 'CLOSED', 'CANCELLED')),
CONSTRAINT dq_orders_amount_range EXPECT (amount >= 0 AND amount <= 100000) ON VIOLATION DROP ROW,
CONSTRAINT dq_orders_ship_after_order EXPECT (ship_date IS NULL OR ship_date >= order_date)
