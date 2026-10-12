-- Email the data steward when a native_dq check fails on Snowflake.
--
-- How it works: a Snowflake alert checks every 15 minutes for failed expectations newer than the last
-- email it sent. When it finds some, it calls a procedure that sends one email per steward, listing that
-- steward's failed rules, then moves the watermark forward.
--
-- Placeholders to replace (no secrets in this file):
--   <OPS_DB>.<OPS_SCHEMA>       where the alert, procedure and watermark live, e.g. ANALYTICS_PROD.DQ_OPS
--   <CATALOG_VIEW>              the dq_rule_catalog view dbt built, e.g. ANALYTICS_PROD.SALES.DQ_RULE_CATALOG
--   <WAREHOUSE>                 a small warehouse for the alert
--   <ALERT_ROLE>                the role that owns the alert and procedure
--   steward addresses           the stewards in your rules YAML
--
-- Not yet run against a live Snowflake account. Test in dev first.
--
-- Docs:
--   https://docs.snowflake.com/en/user-guide/notifications/email-notifications
--   https://docs.snowflake.com/en/sql-reference/stored-procedures/system_send_email
--   https://docs.snowflake.com/en/sql-reference/sql/create-alert
--   https://docs.snowflake.com/en/user-guide/alerts
--   https://docs.snowflake.com/en/sql-reference/local/data_quality_monitoring_expectation_status

------------------------------------------------------------------------------------------------------
-- 1. Once, as ACCOUNTADMIN (or a role with CREATE INTEGRATION on the account).
--    Every recipient must be a user in this Snowflake account with a verified email address,
--    or CREATE NOTIFICATION INTEGRATION fails. Stewards outside Snowflake cannot be emailed this way.
------------------------------------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

CREATE NOTIFICATION INTEGRATION IF NOT EXISTS DQ_STEWARD_EMAIL
  TYPE = EMAIL
  ENABLED = TRUE
  ALLOWED_RECIPIENTS = ('steward.sales@example.com', 'steward.finance@example.com', 'steward.crm@example.com');

GRANT USAGE ON INTEGRATION DQ_STEWARD_EMAIL TO ROLE <ALERT_ROLE>;
GRANT EXECUTE ALERT ON ACCOUNT TO ROLE <ALERT_ROLE>;              -- only ACCOUNTADMIN can grant this
GRANT APPLICATION ROLE SNOWFLAKE.DATA_QUALITY_MONITORING_VIEWER TO ROLE <ALERT_ROLE>;
-- Reading results also needs SELECT (or OWNERSHIP) on each checked table.

------------------------------------------------------------------------------------------------------
-- 2. As <ALERT_ROLE>.
------------------------------------------------------------------------------------------------------
USE ROLE <ALERT_ROLE>;

CREATE TABLE IF NOT EXISTS <OPS_DB>.<OPS_SCHEMA>.DQ_ALERT_WATERMARK (
  last_measurement_time TIMESTAMP_LTZ
);

CREATE OR REPLACE PROCEDURE <OPS_DB>.<OPS_SCHEMA>.DQ_NOTIFY_STEWARDS()
  RETURNS VARCHAR
  LANGUAGE SQL
  EXECUTE AS OWNER
AS
$$
DECLARE
  since TIMESTAMP_LTZ;
  until TIMESTAMP_LTZ;
  sent INTEGER DEFAULT 0;
  recipient VARCHAR;
  subject VARCHAR;
  body VARCHAR;
BEGIN
  SELECT COALESCE(MAX(last_measurement_time), DATEADD('hour', -24, CURRENT_TIMESTAMP()))
    INTO :since
    FROM <OPS_DB>.<OPS_SCHEMA>.DQ_ALERT_WATERMARK;
  -- Results land a few minutes after they are measured; leave a margin so none are skipped.
  until := DATEADD('minute', -10, CURRENT_TIMESTAMP());

  LET failures RESULTSET := (
    SELECT
      c.steward,
      COUNT(*) AS failed_checks,
      LISTAGG(
        c.severity || ' | ' || c.table_full_name || COALESCE('.' || NULLIF(c.column_name, ''), '')
          || ' | ' || c.rule_name || ' (' || c.rule_id || ')'
          || ' | result ' || TO_VARCHAR(s.value) || ', expected ' || s.expectation_expression
          || ' | ' || TO_VARCHAR(s.measurement_time, 'YYYY-MM-DD HH24:MI TZH:TZM'),
        '\n') WITHIN GROUP (ORDER BY c.severity, c.table_full_name, c.rule_id) AS lines
    FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_EXPECTATION_STATUS s
    JOIN <CATALOG_VIEW> c
      ON c.result_name = UPPER(s.expectation_name)
     AND c.table_full_name = UPPER(s.table_database || '.' || s.table_schema || '.' || s.table_name)
    WHERE s.expectation_violated
      AND s.measurement_time > :since
      AND s.measurement_time <= :until
    GROUP BY c.steward
  );
  LET c1 CURSOR FOR failures;

  FOR r IN c1 DO
    recipient := r.steward;
    subject := 'Data quality: ' || r.failed_checks || ' check(s) failed';
    body := 'These data quality checks failed since ' || TO_VARCHAR(:since, 'YYYY-MM-DD HH24:MI TZH:TZM') || ':\n\n'
            || 'severity | table.column | rule | result | measured\n'
            || r.lines
            || '\n\nScores and trends: open the data quality report in Power BI.';
    CALL SYSTEM$SEND_EMAIL('DQ_STEWARD_EMAIL', :recipient, :subject, :body);
    sent := sent + 1;
  END FOR;

  DELETE FROM <OPS_DB>.<OPS_SCHEMA>.DQ_ALERT_WATERMARK;
  INSERT INTO <OPS_DB>.<OPS_SCHEMA>.DQ_ALERT_WATERMARK VALUES (:until);
  RETURN sent || ' email(s) sent';
END;
$$;

CREATE OR REPLACE ALERT <OPS_DB>.<OPS_SCHEMA>.DQ_STEWARD_ALERT
  WAREHOUSE = <WAREHOUSE>
  SCHEDULE = '15 MINUTE'
  IF (EXISTS (
    SELECT 1
    FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_EXPECTATION_STATUS s
    WHERE s.expectation_violated
      AND STARTSWITH(UPPER(s.expectation_name), 'DQ_')
      AND s.measurement_time > (
        SELECT COALESCE(MAX(last_measurement_time), DATEADD('hour', -24, CURRENT_TIMESTAMP()))
        FROM <OPS_DB>.<OPS_SCHEMA>.DQ_ALERT_WATERMARK)
      AND s.measurement_time <= DATEADD('minute', -10, CURRENT_TIMESTAMP())
  ))
  THEN
    CALL <OPS_DB>.<OPS_SCHEMA>.DQ_NOTIFY_STEWARDS();

-- New alerts are created suspended.
ALTER ALERT <OPS_DB>.<OPS_SCHEMA>.DQ_STEWARD_ALERT RESUME;

-- Check it:
--   SHOW ALERTS IN SCHEMA <OPS_DB>.<OPS_SCHEMA>;
--   SELECT * FROM TABLE(INFORMATION_SCHEMA.ALERT_HISTORY()) ORDER BY scheduled_time DESC LIMIT 20;
--   CALL <OPS_DB>.<OPS_SCHEMA>.DQ_NOTIFY_STEWARDS();   -- run by hand
