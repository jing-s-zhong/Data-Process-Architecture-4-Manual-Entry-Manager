# Data Process Architecture (4) Manual Entry Manager
For some revenue sources, we don’t have any daily report available from the vendors, but internally we need a daily number somehow for management to monitor the business healthy. The most common cases in this scenario are that we are able to get a monthly revenue forecast at the beginning of each month based on the vendor’s agreement. After the month is closed, then we can get a real revenue number for that month. We call generate the daily estimated revenue based on the average of the monthly forecast at the beginning of the month, later we replace these daily estimated revenue with the daily average of the real monthly revenue once we have the real revenue available. We call these calculated revenue as the manual entries. Here we need to develop a solution to manage the manual entries automatically.


## I. Design & Implementation
As the snowflake supports VARIANT data, which allows us to use the advanced data types like array, set or JSON object to manage the complicated data and simplify the solution implementation. Here we use one table to store the description (or definition) of above mentioned cases, then we develop a view to interpret the case definition data into the daily revenue numbers. The view will exposure the data just like a regular RDMS view, which allows us to query the data with regular SQL statement and summarize them.

In order to manage the data, we need to develop two sets of stored procedures. One set of stored procedures are used for automated snowflake tasks to generate the data automatically; Another set stored procedures are used for manual correct the auto-generated data or manually enter the real revenue numbers after the month is closed.


### A. The Case Description Table
The case description table is defined by following Snowflake SQL script. The case description table contains the basic information of the sell-side contracts, like year-month, contract_id, monthly_revenue_forecast and monthly_actual_revenue. It also contains a set of dates of the contract is underway. At the beginning of the month, the date-set (we use an array instead!) is created as a empty one, later a daily automated task will insert a date-id in to the set each day by detecting whether the contract “is_enabled” and “manual_entry_allowed”.

Script-1 The SQL definition of the case description table

```
CREATE OR REPLACE SEQUENCE SELLSIDE_CONTRACT_MANUAL_ENTRY_CONFIGURATION_SEQ START = 1 INCREMENT = 1;
ALTER SEQUENCE IF EXISTS SELLSIDE_CONTRACT_MANUAL_ENTRY_CONFIGURATION_SEQ
SET COMMENT = 'Used to generate the default identity value for "SELLSIDE_CONTRACT_MANUAL_ENTRY_CONFIGURATION"';

CREATE OR REPLACE TABLE SELLSIDE_CONTRACT_MANUAL_ENTRY_CONFIGURATION (
  ID INTEGER DEFAULT SELLSIDE_CONTRACT_MANUAL_ENTRY_CONFIGURATION_SEQ.NEXTVAL,
  SELLSIDE_CONTRACT_ID NUMBER,
  REVENUE_MONTH DATE,
  MONTHLY_REVENUE_FORECAST FLOAT,
  MONTHLY_REVENUE_ACTUAL FLOAT,
  DATES_IN_MONTH VARIANT
  )
COMMENT = 'This table is used to store and manage the manual entry of the revenue data';
```

### B. Data Interpret View
The data interpret view is defined by following Snowflake SQL script. The view will generate a daily estimated revenue by calculating the daily average of the monthly actual revenue over the operated dates. If monthly actual revenue is not available yet at beginning of the month, the daily estimated revenue will be generated by calculating the daily average on the monthly forecast over the days of the full month.

Script-2 The SQL definition of the data interpret view

```
CREATE OR REPLACE VIEW SELLSIDE_DAILY_MANUAL_ENTRY
AS
SELECT DATEADD(DAY, F.VALUE - 1, DATE_TRUNC('MONTH', C.REVENUE_MONTH)) DATA_TS
	,DEFAULT_PRODUCT_LINE_ID PRODUCT_LINE_ID
	,P.NETWORK_ID
	,P.ACCOUNT_ID_LOOKUP_VALUE ACCOUNT_ID
	,C.SELLSIDE_CONTRACT_ID
	,M.CURRENCY_CODE
	//,C.VENDOR_MONTHLY_REVENUE_FORECAST
	//,C.MONTHLY_REVENUE_ACTUAL
	//,DATE_PART(DAY,LAST_DAY(C.REVENUE_MONTH)) DAYS_IN_MONTH
	//,NULLIF(ARRAY_SIZE(DATES_IN_MONTH),0) DAYS_OF_FULLFILLING
	,C.MONTHLY_REVENUE_FORECAST / DATE_PART(DAY, LAST_DAY(C.REVENUE_MONTH)) AVERAGE_DAILY_FORECAST
	,C.MONTHLY_REVENUE_ACTUAL / NULLIF(ARRAY_SIZE(DATES_IN_MONTH), 0) AVERAGE_DAILY_REVENUE
	,NULL::INT BIDDED_SEARCHES
	,NULL::INT CLICKS
	,COALESCE(
		C.MONTHLY_REVENUE_ACTUAL / NULLIF(ARRAY_SIZE(DATES_IN_MONTH), 0),
		C.MONTHLY_REVENUE_FORECAST / DATE_PART(DAY, LAST_DAY(C.REVENUE_MONTH))
		) ESTIMATED_REVENUE
FROM SELLSIDE_CONTRACT_MANUAL_ENTRY_CONFIGURATION C
JOIN BI.COMMON.SELLSIDE_CONTRACTS P
ON C.SELLSIDE_CONTRACT_ID = P.CONTRACT_ID
LEFT JOIN BI.COMMON.ACCOUNT_METADATA_MAPPINGS M
ON P.BI_ACCOUNT_ID = M.BI_ACCOUNT_ID
,LATERAL FLATTEN (INPUT => C.DATES_IN_MONTH) F
;
ALTER VIEW SELLSIDE_DAILY_MANUAL_ENTRY
SET COMMENT = 'This table is used to exposure the manual entry of the revenue data';
```

### C. Procedures for Automation
We need two stored procedures for solution automation. (1) At the end of each month, we run a stored procedure to setup a row of forecast revenue for next month of each enabled contract, based on the most recent month we have the business with the vendor. (2) At beginning of each day, we run a stored procedure to add a business date element for all enabled contract

Script-3 The SQL definition of the monthly setup procedure

```
CREATE OR REPLACE PROCEDURE SELLSIDE_CONTRACT_MANUAL_ENTRY_MONTHLY_SETUP (REVENUE_MONTH VARCHAR)
RETURNS VARCHAR
LANGUAGE javascript
COMMENT = 'This SP is scheduled by a automated monthly task to renew the monthly contracts at the last minute of current month
    (1) The renewal result is controlled by both "IS_ENABALED" and "MANUAL_ENTRY_SCHEDULE_ALLOWED" of the SELLSIDE_CONTRACTS table
    (2) Those single-day-entry with the "MONTHLY_REVENUE_FORECAST" as a NULL will not be renewed.'
AS
$$
try {
var queryText = '';
var sqlScript = `
MERGE INTO SELLSIDE_CONTRACT_MANUAL_ENTRY_CONFIGURATION D
USING (
	SELECT C.SELLSIDE_CONTRACT_ID
		,DATE_TRUNC('MONTH', TO_DATE(:1)) REVENUE_MONTH
		,C.MONTHLY_REVENUE_FORECAST
		,NULL MONTHLY_REVENUE_ACTUAL
		,ARRAY_CONSTRUCT() DATES_IN_MONTH
	FROM SELLSIDE_CONTRACT_MANUAL_ENTRY_CONFIGURATION C
	JOIN (
		SELECT a.SELLSIDE_CONTRACT_ID
			,MAX(a.REVENUE_MONTH) REVENUE_MONTH
		FROM SELLSIDE_CONTRACT_MANUAL_ENTRY_CONFIGURATION a
		JOIN BI.COMMON.SELLSIDE_CONTRACTS b
			ON a.SELLSIDE_CONTRACT_ID = b.CONTRACT_ID
			AND b.MANUAL_ENTRY_SCHEDULE_ALLOWED
			AND b.IS_ENABLED
		WHERE MONTHLY_REVENUE_FORECAST IS NOT NULL
		GROUP BY 1
		) F
	ON C.SELLSIDE_CONTRACT_ID = F.SELLSIDE_CONTRACT_ID
	AND C.REVENUE_MONTH = F.REVENUE_MONTH
	) S
ON D.SELLSIDE_CONTRACT_ID = S.SELLSIDE_CONTRACT_ID
	AND D.REVENUE_MONTH = S.REVENUE_MONTH
WHEN MATCHED THEN
	UPDATE SET
		MONTHLY_REVENUE_FORECAST = S.MONTHLY_REVENUE_FORECAST
		,ID = D.ID
WHEN NOT MATCHED THEN
	INSERT (
		SELLSIDE_CONTRACT_ID
		,REVENUE_MONTH
		,MONTHLY_REVENUE_FORECAST
		,MONTHLY_REVENUE_ACTUAL
		,DATES_IN_MONTH
		)
	VALUES (
		S.SELLSIDE_CONTRACT_ID
		,S.REVENUE_MONTH
		,S.MONTHLY_REVENUE_FORECAST
		,S.MONTHLY_REVENUE_ACTUAL
		,S.DATES_IN_MONTH
		);
`;

var sqlStmt = snowflake.createStatement({
    sqlText: sqlScript,
    binds: [REVENUE_MONTH]
    });

var result = sqlStmt.execute();

queryText = sqlStmt.getSqlText()
    .replace(/:1/g, "'" + REVENUE_MONTH + "'");

return queryText;

} catch(err) {

return err;

}
$$;
```

Script-4 The SQL definition of the daily update procedure

```
CREATE OR REPLACE PROCEDURE SELLSIDE_CONTRACT_MANUAL_ENTRY_DAILY_UPDATE (REVENUE_DATE VARCHAR)
RETURNS VARCHAR
LANGUAGE javascript
COMMENT = 'This SP is scheduled by a daily automated task to add the daily indicators to all MANUAL_ENTRY_SCHEDULE_ALLOWED contracts
    (1) The renewal result is controlled by both "IS_ENABALED" and "MANUAL_ENTRY_SCHEDULE_ALLOWED" of the SELLSIDE_CONTRACTS
    (2) If the argument of REVENUE_DATE is not presented, it will use current date as the date value'
AS
$$
try {
var queryText = '';
var sqlScript = `
MERGE INTO SELLSIDE_CONTRACT_MANUAL_ENTRY_CONFIGURATION D
USING (
	SELECT C.SELLSIDE_CONTRACT_ID
		,C.REVENUE_MONTH
		,C.MONTHLY_REVENUE_FORECAST
		,C.MONTHLY_REVENUE_ACTUAL
		,ARRAY_AGG(DISTINCT F.VALUE) WITHIN GROUP (ORDER BY F.VALUE) DATES_IN_MONTH
	FROM (
		SELECT a.*, ARRAY_APPEND(a.DATES_IN_MONTH, DATE_PART(DAY, TO_DATE(:1))) TEMP_DATES
		FROM SELLSIDE_CONTRACT_MANUAL_ENTRY_CONFIGURATION a
		JOIN BI.COMMON.SELLSIDE_CONTRACTS b
            ON a.SELLSIDE_CONTRACT_ID = b.CONTRACT_ID
		WHERE a.REVENUE_MONTH = DATE_TRUNC('MONTH', COALESCE(TO_DATE(:1), CURRENT_DATE()))
			AND b.MANUAL_ENTRY_SCHEDULE_ALLOWED
			AND b.IS_ENABLED
		) C
		,LATERAL FLATTEN(INPUT => TEMP_DATES) F
	GROUP BY C.SELLSIDE_CONTRACT_ID
		,C.REVENUE_MONTH
		,C.MONTHLY_REVENUE_FORECAST
		,C.MONTHLY_REVENUE_ACTUAL
		//ORDER BY 2,1
	) S
ON D.SELLSIDE_CONTRACT_ID = S.SELLSIDE_CONTRACT_ID
    AND D.REVENUE_MONTH = S.REVENUE_MONTH
WHEN MATCHED THEN
	UPDATE SET
		DATES_IN_MONTH = S.DATES_IN_MONTH
		,ID = D.ID
WHEN NOT MATCHED THEN
	INSERT (
		SELLSIDE_CONTRACT_ID
		,REVENUE_MONTH
		,MONTHLY_REVENUE_FORECAST
		,MONTHLY_REVENUE_ACTUAL
		,DATES_IN_MONTH
		)
	VALUES (
		S.SELLSIDE_CONTRACT_ID
		,S.REVENUE_MONTH
		,S.MONTHLY_REVENUE_FORECAST
		,S.MONTHLY_REVENUE_ACTUAL
		,S.DATES_IN_MONTH
		);
`;

var sqlStmt = snowflake.createStatement({
    sqlText: sqlScript,
    binds: [REVENUE_DATE]
    });

var result = sqlStmt.execute();

queryText = sqlStmt.getSqlText()
    .replace(/:1/g, "'" + REVENUE_DATE + "'");

return queryText;

} catch(err) {

return err;

}
$$;
```

### D. Procedures for Manual Management
We also need some stored procedures to manage the data manually. (1) After a month closed, we run a stored procedure to fill in the real revenue numbers of a contract manually. This stored procedure also supports us to change a forecast number after it is created. (2) In case of we have some business dates are not correctly generated by the automation task, we need to run a stored procedure to correct the date by adding or removing. (3) Some time we may need a one time manual entry for a missed revenue, and this kind of manual entry will not repeat. We need a stored procedure to manage this kind of data.

Script-5 The SQL definition of the monthly manual update procedure

```
CREATE OR REPLACE PROCEDURE SELLSIDE_CONTRACT_MANUAL_ENTRY_MONTHLY_UPDATE (
	REVENUE_MONTH VARCHAR
	,SELLSIDE_CONTRACT_ID FLOAT
	,MONTHLY_REVENUE_FORECAST FLOAT
	,MONTHLY_REVENUE_ACTUAL FLOAT
	)
RETURNS VARCHAR
LANGUAGE javascript
COMMENT = 'This SP is manually executed by a person to fill the actual bill or modify the contract budget setting
    (1) If MONTHLY_REVENUE_FORECAST argument is presented as a minus value, it will keep the existing budget value no change
    (2) If MONTHLY_REVENUE_ACTUAL argument is presented as -1 or NULL, it will reset the existing MONTHLY_REVENUE_ACTUAL to NULL'
AS
$$
try {
var queryText = '';
var sqlScript = `
UPDATE SELLSIDE_CONTRACT_MANUAL_ENTRY_CONFIGURATION
SET MONTHLY_REVENUE_FORECAST = CASE WHEN :3 >= 0 THEN :3 ELSE MONTHLY_REVENUE_FORECAST END
    ,MONTHLY_REVENUE_ACTUAL = NULLIF(:4, -1)
    ,ID = ID
WHERE REVENUE_MONTH = DATE_TRUNC('MONTH', TO_DATE(:1))
AND SELLSIDE_CONTRACT_ID = :2
`;

var sqlStmt = snowflake.createStatement({
    sqlText: sqlScript,
    binds: [REVENUE_MONTH, SELLSIDE_CONTRACT_ID, MONTHLY_REVENUE_FORECAST, MONTHLY_REVENUE_ACTUAL]
    });

var result = sqlStmt.execute();

queryText = sqlStmt.getSqlText()
    .replace(/:1/g, "'" + REVENUE_MONTH + "'")
    .replace(/:2/g, SELLSIDE_CONTRACT_ID)
    .replace(/:3/g, MONTHLY_REVENUE_FORECAST)
    .replace(/:4/g, MONTHLY_REVENUE_ACTUAL);

return queryText;

} catch(err) {

return err;

}
$$;
```

Script-6 The SQL definition of the manual maintenance procedure

```
CREATE OR REPLACE PROCEDURE SELLSIDE_CONTRACT_MANUAL_ENTRY_DAILY_UPDATE (
	REVENUE_DATE VARCHAR
	,SELLSIDE_CONTRACT_ID FLOAT
	,DATE_WILL_BE_REMAINED BOOLEAN
)
RETURNS VARCHAR
LANGUAGE javascript
COMMENT = 'This SP is manually executed by a person to modify the date indicators of a contract
    (1) The result is controlled by the "MANUAL_ENTRY_SCHEDULE_ALLOWED"
    (2) The data must be an automated manual entry, that means the MONTHLY_REVENUE_FORECAST containing a not null value
    (3) If the argument DATE_WILL_BE_REMAINED is presented as "True" to set a date; if it is presented as "False", it will unset a date
	(4) In case of wrong removing a configuration row, so it does not allow unset the dates array to an empty one'
AS
$$
try {
var queryText = '';
var sqlScript = `
MERGE INTO SELLSIDE_CONTRACT_MANUAL_ENTRY_CONFIGURATION D
USING (
	SELECT C.SELLSIDE_CONTRACT_ID
		,C.REVENUE_MONTH
		,C.MONTHLY_REVENUE_FORECAST
		,C.MONTHLY_REVENUE_ACTUAL
		,ARRAY_AGG(DISTINCT F.VALUE) WITHIN GROUP (ORDER BY F.VALUE) DATES_IN_MONTH
    FROM (
        SELECT a.*, ARRAY_APPEND(a.DATES_IN_MONTH, DATE_PART(DAY, TO_DATE(:1))) TEMP_DATES
        FROM SELLSIDE_CONTRACT_MANUAL_ENTRY_CONFIGURATION a
        JOIN BI.COMMON.SELLSIDE_CONTRACTS b
            ON a.SELLSIDE_CONTRACT_ID = b.CONTRACT_ID
        WHERE a.REVENUE_MONTH = DATE_TRUNC('MONTH', COALESCE(TO_DATE(:1), CURRENT_DATE()))
            AND a.SELLSIDE_CONTRACT_ID = :2
            AND a.MONTHLY_REVENUE_FORECAST IS NOT NULL
            AND b.MANUAL_ENTRY_SCHEDULE_ALLOWED
        ) C
        ,LATERAL FLATTEN(INPUT => TEMP_DATES) F
	WHERE F.VALUE <> DATE_PART(DAY, TO_DATE(:1)) OR (1 = :3)
	GROUP BY C.SELLSIDE_CONTRACT_ID
		,C.REVENUE_MONTH
		,C.MONTHLY_REVENUE_FORECAST
		,C.MONTHLY_REVENUE_ACTUAL
	//ORDER BY 2,1
	) S
ON D.SELLSIDE_CONTRACT_ID = S.SELLSIDE_CONTRACT_ID
    AND D.REVENUE_MONTH = S.REVENUE_MONTH
WHEN MATCHED THEN
	UPDATE SET
		DATES_IN_MONTH = S.DATES_IN_MONTH
		,ID = D.ID
WHEN NOT MATCHED THEN
	INSERT (
		SELLSIDE_CONTRACT_ID
		,REVENUE_MONTH
		,MONTHLY_REVENUE_FORECAST
		,MONTHLY_REVENUE_ACTUAL
		,DATES_IN_MONTH
		)
	VALUES (
		S.SELLSIDE_CONTRACT_ID
		,S.REVENUE_MONTH
		,S.MONTHLY_REVENUE_FORECAST
		,S.MONTHLY_REVENUE_ACTUAL
		,S.DATES_IN_MONTH
		);
`;

var sqlStmt = snowflake.createStatement({
    sqlText: sqlScript,
    binds: [REVENUE_DATE, SELLSIDE_CONTRACT_ID, DATE_WILL_BE_REMAINED]
    });

var result = sqlStmt.execute();

queryText = sqlStmt.getSqlText()
    .replace(/:1/g, "'" + REVENUE_DATE + "'")
    .replace(/:2/g, SELLSIDE_CONTRACT_ID)
    .replace(/:3/g, DATE_WILL_BE_REMAINED);

return queryText;

} catch(err) {

return err;

}
$$;
```

Script-7 The SQL definition of the single day manual entry procedure

```
CREATE OR REPLACE PROCEDURE SELLSIDE_CONTRACT_MANUAL_ENTRY_SINGLE_DAY_INSERT (
	REVENUE_DATE VARCHAR
	,SELLSIDE_CONTRACT_ID FLOAT
	,MONTHLY_REVENUE_ACTUAL FLOAT
	)
RETURNS VARCHAR
LANGUAGE javascript
COMMENT = 'This SP is manually executed by a person to add a single-day manual entry
    (1) The result is controlled by the "MANUAL_ENTRY_SCHEDULE_ALLOWED" of the SELLSIDE_CONTRACTS
    (2) The single-day manual entry will maintain the MONTHLY_REVENUE_FORECAST as NULL internally to distinct from the automated manual entries
    (3) If MONTHLY_REVENUE_ACTUAL argument is presented as -1 or NULL, it will remove a single-day manual entry from table'
AS
$$
try {
var queryText = '';
var sqlScript = `
MERGE INTO SELLSIDE_CONTRACT_MANUAL_ENTRY_CONFIGURATION D
USING (
    SELECT CONTRACT_ID SELLSIDE_CONTRACT_ID,
        DATE_TRUNC('MONTH', TO_DATE(:1)) REVENUE_MONTH,
        NULL::FLOAT MONTHLY_REVENUE_FORECAST,
        :3 MONTHLY_REVENUE_ACTUAL,
        ARRAY_CONSTRUCT(DATE_PART(DAY, TO_DATE(:1))) DATES_IN_MONTH
    FROM BI.COMMON.SELLSIDE_CONTRACTS
    WHERE CONTRACT_ID = :2
) S
ON D.SELLSIDE_CONTRACT_ID = S.SELLSIDE_CONTRACT_ID
	AND D.REVENUE_MONTH = S.REVENUE_MONTH
    AND D.DATES_IN_MONTH[0] = S.DATES_IN_MONTH[0]
    AND ARRAY_SIZE(D.DATES_IN_MONTH) = 1
    AND D.MONTHLY_REVENUE_FORECAST IS NULL
WHEN MATCHED AND :3 = -1 THEN
	DELETE
WHEN MATCHED AND :3 > 0 THEN
	UPDATE SET
		MONTHLY_REVENUE_ACTUAL = S.MONTHLY_REVENUE_ACTUAL
        ,DATES_IN_MONTH = S.DATES_IN_MONTH
		,ID = D.ID
WHEN NOT MATCHED THEN
	INSERT (
		SELLSIDE_CONTRACT_ID
		,REVENUE_MONTH
		,MONTHLY_REVENUE_FORECAST
		,MONTHLY_REVENUE_ACTUAL
		,DATES_IN_MONTH
		)
	VALUES (
		S.SELLSIDE_CONTRACT_ID
		,S.REVENUE_MONTH
		,S.MONTHLY_REVENUE_FORECAST
		,S.MONTHLY_REVENUE_ACTUAL
		,S.DATES_IN_MONTH
		);
`;

var sqlStmt = snowflake.createStatement({
    sqlText: sqlScript,
    binds: [REVENUE_DATE, SELLSIDE_CONTRACT_ID, MONTHLY_REVENUE_ACTUAL]
    });

var result = sqlStmt.execute();

queryText = sqlStmt.getSqlText()
    .replace(/:1/g, "'" + REVENUE_DATE + "'")
    .replace(/:2/g, SELLSIDE_CONTRACT_ID)
    .replace(/:3/g, MONTHLY_REVENUE_ACTUAL);

return queryText;

} catch(err) {

return err;

}
$$;
```

## II. Automation Setup
We need two separate snowflake tasks to make the solution automation. (1) Monthly revenue forecast setup for all enabled and manual entry allowed contracts; (2) Daily business on going update for all enabled and manual entry allowed contracts.



Script-8 The SQL script to create a monthly scheduled snowflake task

```
// Create a task with a monthly schedule
CREATE OR REPLACE TASK SELLSIDE_MANUAL_ENTRY_MONTHLY_SETUP
    WAREHOUSE = S1_BI
    SCHEDULE = 'USING CRON 59 23 L * * UTC'
AS
CALL SELLSIDE_CONTRACT_MANUAL_ENTRY_MONTHLY_SETUP (TO_VARCHAR(CURRENT_DATE()+1));

// Enable the task schedule
ALTER TASK SELLSIDE_MANUAL_ENTRY_MONTHLY_SETUP RESUME;


Script-9 The SQL script to create a daily scheduled snowflake task

// Create a task with a daily schedule
CREATE OR REPLACE TASK SELLSIDE_MANUAL_ENTRY_DAILY_UPDATE
    WAREHOUSE = S1_BI
    SCHEDULE = 'USING CRON 5 0 * * * UTC'
AS
CALL SELLSIDE_CONTRACT_MANUAL_ENTRY_DAILY_UPDATE(TO_VARCHAR(CURRENT_DATE()));

// Enable the task schedule
ALTER TASK SELLSIDE_MANUAL_ENTRY_DAILY_UPDATE RESUME;
```

## III. Manage The Data Manually
In order to maintain the manual entry numbers are correct. We need to enter the real revenue numbers for each contract each month manually. Some time the incorrect data were entered, we may run a stored procedure to correct the data manually.


### A. Fill  The Real Revenue Monthly
After a month closed, we need to manually run a stored procedure to fill in the real revenue of each contract.

Script-10 The SQL script to fill the real revenue monthly

```
SET (
  REVENUE_MONTH,SELLSIDE_CONTRACT_ID,
  MONTHLY_REVENUE_FORECAST,
  MONTHLY_REVENUE_ACTUAL
  ) = ('2020-01-02', 17, -2, 20.5);

CALL SELLSIDE_CONTRACT_MANUAL_ENTRY_MONTHLY_UPDATE(
  $REVENUE_MONTH, $SELLSIDE_CONTRACT_ID,
  $MONTHLY_REVENUE_FORECAST, $MONTHLY_REVENUE_ACTUAL
  );
```
### B. Manually Add or Remove A Date
Some time we may have a date missing from the business date set, or a date is incorrectly added. In this case  we can run a stored procedure to check it and fill the date in the missed date or remove the incorrect date.

Script-11 The SQL script to add a date manually

```
CALL SELLSIDE_CONTRACT_MANUAL_ENTRY_DAILY_UPDATE('2020-01-30',18, true); -- check and add a date in
```

Script-12 The SQL script to remove a date manually

```
CALL SELLSIDE_CONTRACT_MANUAL_ENTRY_DAILY_UPDATE('2020-01-30',18, false); -- check and remove a date
```

### C. Enter A One Time Single Day Revenue
We may have a revenue missed from a contract. In this case we can add a one time manual entry to keep the report correct.



Script-13 The SQL script to add a single day manual entry

```
CALL SELLSIDE_CONTRACT_MANUAL_ENTRY_SINGLE_DAY_INSERT ('2019-12-22',16,0.10);  -- add a single day manual entry
```

Script-14 The SQL script to remove a single day manual entry

```
CALL SELLSIDE_CONTRACT_MANUAL_ENTRY_SINGLE_DAY_INSERT ('2019-12-22',16,-1);   -- remove a single day manual entry
```
