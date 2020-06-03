!set variable_substitution=true;
use database &{db_name};
use schema &{sc_name};
-------------------------------------------------------
-- Stop and remove all tesks
-------------------------------------------------------
-- ALTER TASK SELLSIDE_ACCOUNT_DATA_AVAILABILITY_DETECT_HOURLY SUSPEND;
-- DROP TASK SELLSIDE_ACCOUNT_DATA_AVAILABILITY_DETECT_HOURLY
-- DROP TASK SELLSIDE_ACCOUNT_DATA_SUMMARY_POPULATE_HOURLY
-- DROP TASK SELLSIDE_ACCOUNT_DATA_SUMMARY_PUBLISH_HOURLY
SHOW TASKS;
--
-------------------------------------------------------
-- Remove installer created objects
-------------------------------------------------------
DROP PROCEDURE IF EXISTS &{db_name}.&{sc_name}.SELLSIDE_CONTRACT_MANUAL_ENTRY_DAILY_UPDATE(VARCHAR, FLOAT, BOOLEAN);
DROP PROCEDURE IF EXISTS &{db_name}.&{sc_name}.SELLSIDE_CONTRACT_MANUAL_ENTRY_DAILY_UPDATE(VARCHAR);
DROP PROCEDURE IF EXISTS &{db_name}.&{sc_name}.SELLSIDE_CONTRACT_MANUAL_ENTRY_SINGLE_DAY_INSERT(VARCHAR, FLOAT, FLOAT);
DROP PROCEDURE IF EXISTS &{db_name}.&{sc_name}.SELLSIDE_CONTRACT_MANUAL_ENTRY_MONTHLY_UPDATE(VARCHAR, FLOAT, FLOAT, FLOAT);
DROP PROCEDURE IF EXISTS &{db_name}.&{sc_name}.SELLSIDE_CONTRACT_MANUAL_ENTRY_MONTHLY_SETUP(VARCHAR);
DROP VIEW IF EXISTS &{db_name}.&{sc_name}.SELLSIDE_DAILY_MANUAL_ENTRY;
DROP SEQUENCE IF EXISTS &{db_name}.&{sc_name}.SELLSIDE_CONTRACT_MANUAL_ENTRY_CONFIGURATION_SEQ;
--
DROP SCHEMA IF EXISTS &{db_name}.&{sc_name} RESTRICT;