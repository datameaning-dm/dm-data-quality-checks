-- Privileges for the role that runs `dbt run-operation native_dq_deploy` (and the post-hook) on Snowflake.
-- Placeholders: <DEPLOY_ROLE>, <RUN_ROLE> (the EXECUTE AS ROLE, var native_dq_execute_as_role), <DB>.
-- Data quality monitoring needs Enterprise Edition or higher.
-- Docs: https://docs.snowflake.com/en/user-guide/data-quality-access-control
-- Not yet run against a live Snowflake account.

USE ROLE ACCOUNTADMIN;
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT TO ROLE <DEPLOY_ROLE>;   -- attach DMFs to tables
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT TO ROLE <RUN_ROLE>;

-- Custom DMFs live in <DB>.DATA_QUALITY (var native_dq_dmf_schema).
GRANT CREATE SCHEMA ON DATABASE <DB> TO ROLE <DEPLOY_ROLE>;
-- If the schema already exists and another role owns it:
-- GRANT USAGE, CREATE DATA METRIC FUNCTION ON SCHEMA <DB>.DATA_QUALITY TO ROLE <DEPLOY_ROLE>;

-- The deploy role must own the checked tables (dbt's role usually does), or have SELECT on them and
-- attach with EXECUTE AS ROLE. The run role needs USAGE on the custom DMFs and SELECT on the tables.
GRANT USAGE ON SCHEMA <DB>.DATA_QUALITY TO ROLE <RUN_ROLE>;
GRANT USAGE ON ALL FUNCTIONS IN SCHEMA <DB>.DATA_QUALITY TO ROLE <RUN_ROLE>;

-- Reading results (the dq_results view, Power BI's role):
GRANT APPLICATION ROLE SNOWFLAKE.DATA_QUALITY_MONITORING_VIEWER TO ROLE <DEPLOY_ROLE>;
