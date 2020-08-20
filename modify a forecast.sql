--
-- Go to right DB & Schema
--
USE SCHEMA BI.MANUAL_ENTRY;

-- 
-- Confirm task is idle and right time to make changes
--
SELECT CASE DATEDIFF(HOUR, COMPLETED_TIME, CURRENT_TIMESTAMP) WHEN 0 THEN 'OK' ELSE 'WAIT' END DOABLE
    ,DATEDIFF(MINUTE, CURRENT_TIMESTAMP, DATEADD(MINUTE, 75, DATE_TRUNC(HOUR,COMPLETED_TIME))) NEXT_SCHEDULE_IN_MINUTES
    ,DATEADD(MINUTE, 75, DATE_TRUNC(HOUR,COMPLETED_TIME)) NEXT_SCHEDULE_TIME 
    ,COMPLETED_TIME LAST_COMPLETION_TIME
    ,CURRENT_TIMESTAMP
FROM BI._CONTROL_LOGIC.DATA_AGGREGATION_COMPLETION_TIME
;

--
-- MOdify monthly forecast of '2020-07-01'
--
CALL SELLSIDE_CONTRACT_MANUAL_ENTRY_MONTHLY_UPDATE (
	'2020-07-01'    -- REVENUE_MONTH VARCHAR
	,16             -- SELLSIDE_CONTRACT_ID FLOAT
	,50000          -- MONTHLY_REVENUE_FORECAST FLOAT
	,-1             -- MONTHLY_REVENUE_ACTUAL FLOAT
	);
    
--
-- MOdify monthly forecast of '2020-08-01'
--
CALL SELLSIDE_CONTRACT_MANUAL_ENTRY_MONTHLY_UPDATE (
	'2020-08-01'    -- REVENUE_MONTH VARCHAR
	,16             -- SELLSIDE_CONTRACT_ID FLOAT
	,50000          -- MONTHLY_REVENUE_FORECAST FLOAT
	,-1             -- MONTHLY_REVENUE_ACTUAL FLOAT
	);   

--
-- Confirm the changes correct
--
SELECT REVENUE_MONTH
    ,MONTHLY_REVENUE_FORECAST
    ,MONTHLY_REVENUE_ACTUAL
FROM SELLSIDE_CONTRACT_MANUAL_ENTRY_CONFIGURATION
WHERE SELLSIDE_CONTRACT_ID = 16
ORDER BY REVENUE_MONTH DESC
;

--
-- Confirm the daily numbers
--
SELECT DATA_TS
    ,ESTIMATED_REVENUE
FROM BI.MANUAL_ENTRY.SELLSIDE_DAILY_MANUAL_ENTRY
WHERE SELLSIDE_CONTRACT_ID = 16
AND DATA_TS >= '2020-06-25'
ORDER BY DATA_TS
;