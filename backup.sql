--Backup SQL File in case notebooks have an issue
/*US Flood Vulnerability Solution — Hands-On Lab
Snowflake Summit 2026
In this lab you will build an end-to-end flood vulnerability analysis platform using Snowflake.
By combining Overture Maps building footprints, FEMA risk indices, and CDC social vulnerability data
you will identify buildings at flood risk across Louisiana — the highest flood-risk state in the US.

What You Will Build
A geospatial pipeline identifying buildings within FEMA flood zones
A social vulnerability overlay linking flood exposure to community resilience
Cortex AI document intelligence to parse Louisiana's State Hazard Mitigation Plan
A Cortex Agent for natural-language Q&A over flood risk data
An interactive Streamlit dashboard
Snowflake Features Covered
Feature	Usage
Snowflake Marketplace	Overture Maps Buildings (2.3B footprints)
Geospatial / H3 Functions	Spatial joins, hexagonal indexing
Internal Stages	Loading FEMA NRI + CDC SVI CSVs
Cortex AI (PARSE_DOCUMENT)	Extracting text from flood policy PDFs
Cortex Search	Semantic search over policy documents
Cortex COMPLETE	AI-generated risk summaries
Streamlit in Snowflake	Interactive flood vulnerability dashboard
Dynamic Tables	Automated risk scoring pipeline
⏱ Estimated Time: 90 minutes
📋 Before you start: Make sure you have ACCOUNTADMIN role or equivalent privileges.

Lab 1: Environment Setup
First, we create the database, schema, and warehouse for this lab.
All objects will live in FLOOD_ANALYTICS.FLOOD.
*/


-- ============================================================
-- STEP 1.1: Create database, schema, and warehouse
-- ============================================================
USE ROLE ACCOUNTADMIN;

CREATE DATABASE  IF NOT EXISTS FLOOD_ANALYTICS;
CREATE SCHEMA    IF NOT EXISTS FLOOD_ANALYTICS.FLOOD;

CREATE WAREHOUSE IF NOT EXISTS FLOOD_WH
  WAREHOUSE_SIZE = 'MEDIUM'
  AUTO_SUSPEND   = 120
  AUTO_RESUME    = TRUE
  COMMENT        = 'Warehouse for Flood Vulnerability HOL';

USE DATABASE  FLOOD_ANALYTICS;
USE SCHEMA    FLOOD;
USE WAREHOUSE FLOOD_WH;

SELECT CURRENT_DATABASE(), CURRENT_SCHEMA(), CURRENT_WAREHOUSE();
     
/*Step 1.2 — Install Overture Maps Buildings from Marketplace
This gives you access to 2.3 billion building footprints worldwide.

Log in to Snowsight (https://app.snowflake.com)
Click Marketplace in the left sidebar
Click Snowflake Marketplace
In the search bar, type "Overture Maps - Buildings"
Find the listing by CARTO and click on it
Click the blue Get button (top right)
In the dialog, click on options and then set the database name to OVERTURE_MAPS_BUILDINGS. Make sure there is only one underscore between MAPS and BUILDINGS.
In the roles dropdown, select PUBLIC
Click Get again to confirm
Wait for the share to be mounted (takes ~30 seconds)
How to verify: Go to Data → Databases in the left sidebar. You should see OVERTURE_MAPS_BUILDINGS listed.

ℹ️ Note: This dataset contains 2.3 billion building footprints worldwide.
We filter to Louisiana using a bounding box (lon −94.05 to −88.82, lat 28.93 to 33.02).
*/

-- ============================================================
-- STEP 1.3: Verify Overture Maps Buildings is installed
-- ============================================================
-- Sample 10 Louisiana buildings to confirm access
SELECT
    ID,
    NAMES['primary']::STRING AS NAME,
    SUBTYPE,
    CLASS,
    HEIGHT,
    NUM_FLOORS,
    BBOX
FROM OVERTURE_MAPS_BUILDINGS.CARTO.BUILDING
WHERE BBOX:xmin >= -94.05
  AND BBOX:xmax <= -88.82
  AND BBOX:ymin >=  28.93
  AND BBOX:ymax <=  33.02
LIMIT 10;
     


-- ============================================================
-- STEP 1.4: Extract Louisiana buildings + compute H3 indices
-- ⏳ This scans ~2.3B global rows — expect 3-5 min on MEDIUM
-- ============================================================
CREATE OR REPLACE TABLE BUILDINGS_LA AS
SELECT
    ID,
    NAMES['primary']::STRING                          AS NAME,
    SUBTYPE,
    CLASS,
    HEIGHT,
    NUM_FLOORS,
    GEOMETRY,
    BBOX,
    ST_X(ST_CENTROID(GEOMETRY))                       AS LONGITUDE,
    ST_Y(ST_CENTROID(GEOMETRY))                       AS LATITUDE,
    H3_POINT_TO_CELL_STRING(ST_CENTROID(GEOMETRY), 8) AS H3_INDEX_8,
    H3_POINT_TO_CELL_STRING(ST_CENTROID(GEOMETRY), 6) AS H3_INDEX_6
FROM OVERTURE_MAPS_BUILDINGS.CARTO.BUILDING
WHERE BBOX:xmin >= -94.05
  AND BBOX:xmax <= -88.82
  AND BBOX:ymin >=  28.93
  AND BBOX:ymax <=  33.02;

-- Expected: ~3-4 million buildings
SELECT COUNT(*) AS TOTAL_LA_BUILDINGS FROM BUILDINGS_LA;
     
/*Lab 2: Load FEMA & CDC Reference Data
We will load two pre-downloaded datasets from this GitHub repository. Both files are in the data/ folder — they are automatically uploaded to the stage from the workspace.

File	Source	Rows
data/fema_nri/NRI_CensusTracts_Louisiana.csv	FEMA hazards.fema.gov	1,376 census tracts
data/cdc_svi/SVI_2022_LA.csv	CDC svi.cdc.gov	1,379 census tracts
No manual upload needed — the next cells use COPY FILES INTO to upload directly from the workspace to the stage.


*/
-- ============================================================
-- STEP 2.1: Create internal stage and CSV file format
-- ============================================================
CREATE OR REPLACE STAGE FLOOD_DATA_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Stage for FEMA NRI, CDC SVI CSVs and policy PDFs';

CREATE OR REPLACE FILE FORMAT CSV_FORMAT
  TYPE                         = 'CSV'
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  PARSE_HEADER                 = TRUE
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
  NULL_IF                      = ('', 'NULL', 'None', 'NA', '-999')
  EMPTY_FIELD_AS_NULL          = TRUE;

-- Confirm stage is ready
SHOW STAGES LIKE 'FLOOD_DATA_STAGE';
     

-- ============================================================
-- STEP 3.1: Create the master building-level flood risk table
-- Joins: Buildings -> Parish -> NRI/SVI risk profiles
--
-- Join strategy:
-- 1. Load parish centroids (64 parishes with lat/lon)
-- 2. Aggregate NRI + SVI to parish level (filtering -999 sentinels)
-- 3. For each H3 hex, find the nearest parish centroid (HAVERSINE)
-- 4. Join buildings to their H3 hex -> parish -> risk profile
-- ============================================================

-- Step A: Upload workspace CSVs to stage and load tables
COPY FILES INTO @FLOOD_DATA_STAGE/parish/
FROM 'snow://workspace/USER$.PUBLIC."flood-resilience"/versions/live/'
FILES=('data/parish_centroids/LA_Parish_Centroids.csv');

COPY FILES INTO @FLOOD_DATA_STAGE/nri/
FROM 'snow://workspace/USER$.PUBLIC."flood-resilience"/versions/live/'
FILES=('data/fema_nri/NRI_CensusTracts_Louisiana.csv');

COPY FILES INTO @FLOOD_DATA_STAGE/svi/
FROM 'snow://workspace/USER$.PUBLIC."flood-resilience"/versions/live/'
FILES=('data/cdc_svi/SVI_2022_LA.csv');

-- Load parish centroids
CREATE OR REPLACE TABLE PARISH_CENTROIDS (
    STCOFIPS  STRING,
    PARISH    STRING,
    LATITUDE  FLOAT,
    LONGITUDE FLOAT
);

COPY INTO PARISH_CENTROIDS
FROM @FLOOD_DATA_STAGE/parish/
FILE_FORMAT = CSV_FORMAT
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
ON_ERROR = 'CONTINUE';

SELECT COUNT(*) AS PARISH_COUNT FROM PARISH_CENTROIDS;

-- Load FEMA NRI data
CREATE OR REPLACE TABLE FEMA_NRI
USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
    FROM TABLE(INFER_SCHEMA(
        LOCATION => '@FLOOD_DATA_STAGE/nri/',
        FILE_FORMAT => 'CSV_FORMAT'
    ))
);

COPY INTO FEMA_NRI
FROM @FLOOD_DATA_STAGE/nri/
FILE_FORMAT = CSV_FORMAT
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
ON_ERROR = 'CONTINUE';

SELECT COUNT(*) AS NRI_TRACT_COUNT FROM FEMA_NRI;

-- Load CDC SVI data
CREATE OR REPLACE TABLE CDC_SVI
USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
    FROM TABLE(INFER_SCHEMA(
        LOCATION => '@FLOOD_DATA_STAGE/svi/',
        FILE_FORMAT => 'CSV_FORMAT'
    ))
);

COPY INTO CDC_SVI
FROM @FLOOD_DATA_STAGE/svi/
FILE_FORMAT = CSV_FORMAT
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
ON_ERROR = 'CONTINUE';

SELECT COUNT(*) AS SVI_TRACT_COUNT FROM CDC_SVI;

-- Derive FLOOD_ZONES from NRI inland/coastal flood data
CREATE OR REPLACE TABLE FLOOD_ZONES AS
SELECT
    TRACTFIPS,
    CASE
        WHEN CFLD_RISKR IN ('Very High', 'Relatively High') THEN 'VE'
        WHEN IFLD_RISKR IN ('Very High', 'Relatively High') THEN 'AE'
        WHEN IFLD_RISKR = 'Relatively Moderate' OR CFLD_RISKR = 'Relatively Moderate' THEN 'X500'
        ELSE 'X'
    END AS FLOOD_ZONE,
    CASE
        WHEN CFLD_RISKR IN ('Very High', 'Relatively High') THEN 'Coastal High Hazard Area'
        WHEN IFLD_RISKR IN ('Very High', 'Relatively High') THEN 'Special Flood Hazard Area'
        WHEN IFLD_RISKR = 'Relatively Moderate' OR CFLD_RISKR = 'Relatively Moderate' THEN '500-Year Floodplain'
        ELSE 'Minimal Flood Hazard'
    END AS ZONE_DESCRIPTION,
    CASE
        WHEN CFLD_RISKR IN ('Very High', 'Relatively High') THEN TRUE
        WHEN IFLD_RISKR IN ('Very High', 'Relatively High') THEN TRUE
        ELSE FALSE
    END AS IN_SFHA
FROM FEMA_NRI;

-- Step B: Aggregate NRI + SVI to parish (county) level
-- NOTE: SVI uses -999 as sentinel for missing data - filter these out
CREATE OR REPLACE TABLE COUNTY_RISK_PROFILE AS
SELECT
    nri.STCOFIPS,
    nri.COUNTY                                          AS PARISH,
    ROUND(AVG(nri.RISK_SCORE), 2)                       AS RISK_SCORE,
    MAX(nri.RISK_RATNG)                                 AS RISK_RATNG,
    ROUND(AVG(nri.EAL_VALT), 2)                         AS EXPECTED_ANNUAL_LOSS,
    ROUND(AVG(nri.EAL_VALB), 2)                         AS EAL_BUILDINGS,
    ROUND(AVG(nri.IFLD_RISKS), 2)                       AS INLAND_FLOOD_RISK_SCORE,
    MAX(nri.IFLD_RISKR)                                 AS INLAND_FLOOD_RISK_RATING,
    ROUND(AVG(nri.CFLD_RISKS), 2)                       AS COASTAL_FLOOD_RISK_SCORE,
    MAX(nri.CFLD_RISKR)                                 AS COASTAL_FLOOD_RISK_RATING,
    ROUND(AVG(nri.HRCN_RISKS), 2)                       AS HURRICANE_RISK_SCORE,
    MAX(nri.HRCN_RISKR)                                 AS HURRICANE_RISK_RATING,
    MODE(fz.FLOOD_ZONE)                                 AS FLOOD_ZONE,
    MODE(fz.ZONE_DESCRIPTION)                           AS ZONE_DESCRIPTION,
    COUNT(CASE WHEN fz.IN_SFHA THEN 1 END) > COUNT(*)/2 AS IN_SFHA,
    ROUND(AVG(CASE WHEN svi.RPL_THEMES >= 0 THEN svi.RPL_THEMES END), 4) AS SVI_OVERALL,
    ROUND(AVG(CASE WHEN svi.RPL_THEME1 >= 0 THEN svi.RPL_THEME1 END), 4) AS SVI_SOCIOECONOMIC,
    ROUND(AVG(CASE WHEN svi.RPL_THEME2 >= 0 THEN svi.RPL_THEME2 END), 4) AS SVI_HOUSEHOLD,
    ROUND(AVG(CASE WHEN svi.RPL_THEME4 >= 0 THEN svi.RPL_THEME4 END), 4) AS SVI_HOUSING_TRANSPORT,
    ROUND(AVG(CASE WHEN svi.EPL_MOBILE >= 0 THEN svi.EPL_MOBILE END), 4) AS MOBILE_HOME_PCT,
    ROUND(AVG(CASE WHEN svi.EPL_NOVEH >= 0 THEN svi.EPL_NOVEH END), 4)  AS NO_VEHICLE_PCT,
    ROUND(AVG(CASE WHEN svi.EPL_AGE65 >= 0 THEN svi.EPL_AGE65 END), 4)  AS ELDERLY_PCT,
    SUM(CASE WHEN svi.E_TOTPOP > 0 THEN svi.E_TOTPOP ELSE 0 END)        AS TRACT_POPULATION
FROM FEMA_NRI nri
LEFT JOIN FLOOD_ZONES fz  ON nri.TRACTFIPS = fz.TRACTFIPS
LEFT JOIN CDC_SVI     svi ON nri.TRACTFIPS = svi.FIPS
GROUP BY nri.STCOFIPS, nri.COUNTY;

SELECT COUNT(*) AS PARISH_COUNT FROM COUNTY_RISK_PROFILE;

-- Step C: Map each H3 hex to its nearest parish using HAVERSINE
-- ~4800 distinct H3 hexes x 64 parishes = fast cross join
CREATE OR REPLACE TABLE H3_PARISH_MAP AS
SELECT H3_INDEX_6, STCOFIPS
FROM (
    SELECT
        h.H3_INDEX_6,
        pc.STCOFIPS,
        ROW_NUMBER() OVER (
            PARTITION BY h.H3_INDEX_6
            ORDER BY HAVERSINE(
                ST_Y(H3_CELL_TO_POINT(h.H3_INDEX_6)),
                ST_X(H3_CELL_TO_POINT(h.H3_INDEX_6)),
                pc.LATITUDE,
                pc.LONGITUDE
            )
        ) AS RN
    FROM (SELECT DISTINCT H3_INDEX_6 FROM BUILDINGS_LA) h
    CROSS JOIN PARISH_CENTROIDS pc
)
WHERE RN = 1;

-- Step D: Build final building-level flood risk table
CREATE OR REPLACE TABLE BUILDING_FLOOD_RISK AS
SELECT
    b.ID                                               AS BUILDING_ID,
    b.NAME                                             AS BUILDING_NAME,
    b.SUBTYPE,
    b.CLASS,
    b.HEIGHT,
    b.NUM_FLOORS,
    b.LONGITUDE,
    b.LATITUDE,
    b.H3_INDEX_8,
    b.H3_INDEX_6,
    cr.STCOFIPS                                        AS TRACTFIPS,
    cr.STCOFIPS,
    cr.PARISH,
    cr.RISK_SCORE                                      AS NRI_RISK_SCORE,
    cr.RISK_RATNG                                      AS NRI_RISK_RATING,
    cr.INLAND_FLOOD_RISK_SCORE,
    cr.INLAND_FLOOD_RISK_RATING,
    cr.COASTAL_FLOOD_RISK_SCORE,
    cr.COASTAL_FLOOD_RISK_RATING,
    cr.HURRICANE_RISK_SCORE,
    cr.HURRICANE_RISK_RATING,
    cr.EXPECTED_ANNUAL_LOSS,
    cr.EAL_BUILDINGS,
    cr.FLOOD_ZONE,
    cr.ZONE_DESCRIPTION,
    cr.IN_SFHA                                         AS IN_SPECIAL_FLOOD_HAZARD_AREA,
    cr.SVI_OVERALL,
    cr.SVI_SOCIOECONOMIC,
    cr.SVI_HOUSEHOLD,
    cr.SVI_HOUSING_TRANSPORT,
    cr.MOBILE_HOME_PCT,
    cr.NO_VEHICLE_PCT,
    cr.ELDERLY_PCT,
    cr.TRACT_POPULATION,
    ROUND(
        COALESCE(cr.RISK_SCORE, 0) * 0.40 +
        COALESCE(cr.SVI_OVERALL, 0) * 100 * 0.30 +
        CASE cr.FLOOD_ZONE
            WHEN 'VE'   THEN 100
            WHEN 'AE'   THEN 80
            WHEN 'X500' THEN 40
            ELSE              10
        END * 0.30
    , 2)                                               AS COMPOSITE_VULNERABILITY_SCORE
FROM BUILDINGS_LA b
JOIN H3_PARISH_MAP hpm ON b.H3_INDEX_6 = hpm.H3_INDEX_6
JOIN COUNTY_RISK_PROFILE cr ON hpm.STCOFIPS = cr.STCOFIPS;

SELECT COUNT(*) AS BUILDINGS_WITH_RISK_DATA FROM BUILDING_FLOOD_RISK;
     

-- ============================================================
-- STEP 2.3: Create CDC Social Vulnerability Index (SVI) table
-- The SVI ranks census tracts on 16 social factors across 4 themes:
--   Theme 1: Socioeconomic Status
--   Theme 2: Household Characteristics (age, disability)
--   Theme 3: Racial & Ethnic Minority Status
--   Theme 4: Housing Type & Transportation (mobile homes, no vehicle)
-- RPL_THEMES = overall percentile rank (0-1, higher = more vulnerable)
-- ============================================================
CREATE OR REPLACE TABLE CDC_SVI (
    ST          STRING,
    STATE       STRING,
    ST_ABBR     STRING,
    STCNTY      STRING,
    COUNTY      STRING,
    FIPS        STRING,     -- 11-digit FIPS join key (matches TRACTFIPS in NRI)
    LOCATION    STRING,
    AREA_SQMI   FLOAT,
    E_TOTPOP    FLOAT,      -- Total population estimate
    RPL_THEME1  FLOAT,      -- Socioeconomic vulnerability percentile (0-1)
    EPL_POV150  FLOAT,      -- % below 150% poverty line
    EPL_UNEMP   FLOAT,
    EPL_HBURD   FLOAT,      -- Housing cost burden
    EPL_NOHSDP  FLOAT,
    EPL_UNINSUR FLOAT,      -- Uninsured population
    RPL_THEME2  FLOAT,      -- Household characteristics percentile
    EPL_AGE65   FLOAT,      -- Age 65+ (evacuation difficulty)
    EPL_AGE17   FLOAT,
    EPL_DISABL  FLOAT,      -- Disability
    EPL_SNGPNT  FLOAT,
    EPL_LIMENG  FLOAT,
    RPL_THEME3  FLOAT,      -- Racial/ethnic minority percentile
    EPL_MINRTY  FLOAT,
    RPL_THEME4  FLOAT,      -- Housing/transport percentile
    EPL_MUNIT   FLOAT,
    EPL_MOBILE  FLOAT,      -- Mobile homes (structurally vulnerable to flooding)
    EPL_CROWD   FLOAT,
    EPL_NOVEH   FLOAT,      -- No vehicle (evacuation barrier)
    EPL_GROUPQ  FLOAT,
    RPL_THEMES  FLOAT,      -- OVERALL SVI score (0-1) — primary metric
    F_TOTAL     FLOAT
);

-- ⚠️ Upload SVI_2022_LA.csv to @FLOOD_DATA_STAGE/svi/ first!
COPY INTO CDC_SVI
FROM @FLOOD_DATA_STAGE/svi/
FILE_FORMAT          = CSV_FORMAT
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
ON_ERROR             = 'CONTINUE';

-- ✅ Verify: SVI scores of 0.75+ indicate high social vulnerability
SELECT
    COUNT(*)                               AS TRACT_COUNT,
    ROUND(AVG(RPL_THEMES), 3)              AS AVG_SVI,
    COUNT(CASE WHEN RPL_THEMES >= 0.75 THEN 1 END) AS HIGH_VULN_TRACTS,
    COUNT(CASE WHEN RPL_THEMES < 0.25  THEN 1 END) AS LOW_VULN_TRACTS
FROM CDC_SVI;
     


-- ============================================================
-- STEP 2.4: Derive FEMA flood zone designations from NRI ratings
-- 
-- FEMA flood zone → insurance requirement:
--   VE (Coastal High Hazard)      → Mandatory flood insurance
--   AE (1% annual chance inland)  → Mandatory flood insurance
--   X500 (0.2% annual chance)     → Insurance recommended
--   X (minimal hazard)            → No requirement
-- ============================================================
CREATE OR REPLACE TABLE FLOOD_ZONES AS
SELECT
    TRACTFIPS,
    COUNTY    AS PARISH,
    STCOFIPS,
    CASE
        WHEN CFLD_RISKR IN ('Very High', 'Relatively High') THEN 'VE'
        WHEN IFLD_RISKR IN ('Very High', 'Relatively High') THEN 'AE'
        WHEN IFLD_RISKR  = 'Relatively Moderate'           THEN 'X500'
        ELSE 'X'
    END AS FLOOD_ZONE,
    CASE
        WHEN CFLD_RISKR IN ('Very High', 'Relatively High')
            THEN 'Coastal High Hazard — mandatory flood insurance'
        WHEN IFLD_RISKR IN ('Very High', 'Relatively High')
            THEN '1% Annual Chance Inland Flood — mandatory flood insurance'
        WHEN IFLD_RISKR  = 'Relatively Moderate'
            THEN '0.2% Annual Chance Flood — insurance recommended'
        ELSE 'Minimal Flood Hazard'
    END AS ZONE_DESCRIPTION,
    -- SFHA = Special Flood Hazard Area (AE or VE zones — mandatory insurance)
    (CFLD_RISKR IN ('Very High', 'Relatively High')
     OR IFLD_RISKR IN ('Very High', 'Relatively High')) AS IN_SFHA,
    IFLD_RISKS AS INLAND_FLOOD_RISK_SCORE,
    CFLD_RISKS AS COASTAL_FLOOD_RISK_SCORE,
    HRCN_RISKS AS HURRICANE_RISK_SCORE
FROM FEMA_NRI;

-- Distribution of flood zones
SELECT
    FLOOD_ZONE,
    ZONE_DESCRIPTION,
    COUNT(*) AS TRACTS,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS PCT_OF_TRACTS
FROM FLOOD_ZONES
GROUP BY 1, 2
ORDER BY TRACTS DESC;
/*     
Lab 3: Geospatial Flood Risk Analysis
Now we join 3M+ Louisiana buildings with FEMA risk data and CDC social vulnerability scores.

Why H3 hexagonal indexing?
Instead of expensive point-in-polygon operations, we use Uber's H3 system:

Each building centroid → H3 cell at resolution 8 (~460m diameter)
Census tracts are mapped via their county FIPS identifier
This is 100x faster than traditional spatial predicates on millions of polygons
Composite Vulnerability Score formula:

Score = (NRI Risk Score × 40%) + (SVI Overall × 100 × 30%) + (Flood Zone Exposure × 30%)
Where flood zone exposure: VE=100, AE=80, X500=40, X=10
*/

-- ============================================================
-- STEP 3.1: Create the master building-level flood risk table
-- Joins: Buildings → H3 Parish Map → County Risk Profile
-- Join strategy: buildings.H3_INDEX_6 → parish map → risk profile
-- ============================================================
CREATE OR REPLACE TABLE BUILDING_FLOOD_RISK AS
SELECT
    b.ID                                               AS BUILDING_ID,
    b.NAME                                             AS BUILDING_NAME,
    b.SUBTYPE,
    b.CLASS,
    b.HEIGHT,
    b.NUM_FLOORS,
    b.LONGITUDE,
    b.LATITUDE,
    b.H3_INDEX_8,
    b.H3_INDEX_6,
    cr.STCOFIPS                                        AS TRACTFIPS,
    cr.STCOFIPS,
    cr.PARISH,
    cr.RISK_SCORE                                      AS NRI_RISK_SCORE,
    cr.RISK_RATNG                                      AS NRI_RISK_RATING,
    cr.INLAND_FLOOD_RISK_SCORE,
    cr.INLAND_FLOOD_RISK_RATING,
    cr.COASTAL_FLOOD_RISK_SCORE,
    cr.COASTAL_FLOOD_RISK_RATING,
    cr.HURRICANE_RISK_SCORE,
    cr.HURRICANE_RISK_RATING,
    cr.EXPECTED_ANNUAL_LOSS,
    cr.EAL_BUILDINGS,
    cr.FLOOD_ZONE,
    cr.ZONE_DESCRIPTION,
    cr.IN_SFHA                                         AS IN_SPECIAL_FLOOD_HAZARD_AREA,
    cr.SVI_OVERALL,
    cr.SVI_SOCIOECONOMIC,
    cr.SVI_HOUSEHOLD,
    cr.SVI_HOUSING_TRANSPORT,
    cr.MOBILE_HOME_PCT,
    cr.NO_VEHICLE_PCT,
    cr.ELDERLY_PCT,
    cr.TRACT_POPULATION,
    ROUND(
        COALESCE(cr.RISK_SCORE, 0) * 0.40 +
        COALESCE(cr.SVI_OVERALL, 0) * 100 * 0.30 +
        CASE cr.FLOOD_ZONE
            WHEN 'VE'   THEN 100
            WHEN 'AE'   THEN 80
            WHEN 'X500' THEN 40
            ELSE              10
        END * 0.30
    , 2)                                               AS COMPOSITE_VULNERABILITY_SCORE
FROM BUILDINGS_LA b
JOIN H3_PARISH_MAP hpm ON b.H3_INDEX_6 = hpm.H3_INDEX_6
JOIN COUNTY_RISK_PROFILE cr ON hpm.STCOFIPS = cr.STCOFIPS;

SELECT COUNT(*) AS BUILDINGS_WITH_RISK_DATA FROM BUILDING_FLOOD_RISK;
     
/*💡 Production join approach: For exact building-to-tract assignment, use:

JOIN census_tract_polygons ctp ON ST_WITHIN(b.GEOMETRY, ctp.boundary_geog)
This requires loading US Census TIGER/Line tract boundary shapefiles. For this lab we use the county-level approximation which is accurate enough for parish-level analysis.
*/

-- ============================================================
-- STEP 3.2: Parish-level flood risk summary table
-- NOTE: EXPECTED_ANNUAL_LOSS and EAL_BUILDINGS are parish-level
-- values (same for every building in a parish), so use MAX not SUM
-- NOTE: FLOOD_ZONE is parish-level (MODE of tracts). Use tract-level
-- FLOOD_ZONES table for accurate SFHA percentages.
-- ============================================================
CREATE OR REPLACE TABLE PARISH_FLOOD_SUMMARY AS
WITH parish_sfha AS (
    SELECT
        cr.STCOFIPS,
        ROUND(COUNT(CASE WHEN fz.IN_SFHA THEN 1 END) * 100.0 / COUNT(*), 1) AS PCT_IN_SFHA
    FROM FEMA_NRI nri
    JOIN FLOOD_ZONES fz ON nri.TRACTFIPS = fz.TRACTFIPS
    JOIN COUNTY_RISK_PROFILE cr ON nri.STCOFIPS = cr.STCOFIPS
    GROUP BY cr.STCOFIPS
)
SELECT
    b.PARISH,
    COUNT(*)                                                  AS TOTAL_BUILDINGS,
    ROUND(COUNT(*) * MAX(ps.PCT_IN_SFHA) / 100.0, 0)          AS BUILDINGS_IN_SFHA,
    MAX(ps.PCT_IN_SFHA)                                       AS PCT_IN_SFHA,
    ROUND(AVG(b.NRI_RISK_SCORE), 2)                           AS AVG_NRI_RISK_SCORE,
    ROUND(AVG(b.SVI_OVERALL), 3)                              AS AVG_SVI_SCORE,
    ROUND(AVG(b.COMPOSITE_VULNERABILITY_SCORE), 2)            AS AVG_COMPOSITE_SCORE,
    ROUND(MAX(b.EXPECTED_ANNUAL_LOSS), 0)                     AS TOTAL_EXPECTED_ANNUAL_LOSS,
    ROUND(MAX(b.EAL_BUILDINGS), 0)                            AS BUILDING_EXPECTED_ANNUAL_LOSS,
    COUNT(CASE WHEN b.FLOOD_ZONE = 'VE'   THEN 1 END)         AS BUILDINGS_COASTAL_ZONE,
    COUNT(CASE WHEN b.FLOOD_ZONE = 'AE'   THEN 1 END)         AS BUILDINGS_RIVERINE_ZONE,
    COUNT(CASE WHEN b.FLOOD_ZONE = 'X500' THEN 1 END)         AS BUILDINGS_MODERATE_ZONE,
    COUNT(CASE WHEN b.SVI_OVERALL >= 0.75  THEN 1 END)        AS HIGH_SOCIAL_VULN_BUILDINGS
FROM BUILDING_FLOOD_RISK b
JOIN parish_sfha ps ON b.STCOFIPS = ps.STCOFIPS
WHERE b.PARISH IS NOT NULL
GROUP BY b.PARISH
ORDER BY AVG_COMPOSITE_SCORE DESC;

SELECT
    PARISH, TOTAL_BUILDINGS, BUILDINGS_IN_SFHA, PCT_IN_SFHA,
    AVG_NRI_RISK_SCORE, AVG_SVI_SCORE, AVG_COMPOSITE_SCORE,
    TO_CHAR(TOTAL_EXPECTED_ANNUAL_LOSS, '$999,999,999') AS ANNUAL_LOSS
FROM PARISH_FLOOD_SUMMARY
ORDER BY PCT_IN_SFHA DESC
LIMIT 10;
     

-- ============================================================
-- STEP 3.3: H3 hexagonal risk heatmap table (for visualization)
-- Resolution 6 hexagons (~36km across) for readable map tiles
-- ============================================================
CREATE OR REPLACE TABLE H3_FLOOD_RISK_MAP AS
SELECT
    H3_INDEX_6,
    ST_ASWKT(H3_CELL_TO_BOUNDARY(H3_INDEX_6))          AS HEX_BOUNDARY_WKT,
    COUNT(*)                                      AS BUILDING_COUNT,
    COUNT(CASE WHEN IN_SPECIAL_FLOOD_HAZARD_AREA THEN 1 END)
                                                  AS BUILDINGS_AT_RISK,
    ROUND(AVG(COMPOSITE_VULNERABILITY_SCORE), 2)  AS AVG_VULNERABILITY,
    ROUND(AVG(NRI_RISK_SCORE), 2)                 AS AVG_NRI_SCORE,
    ROUND(AVG(SVI_OVERALL), 3)                    AS AVG_SVI,
    ROUND(SUM(EXPECTED_ANNUAL_LOSS), 0)           AS TOTAL_EAL,
    MAX(PARISH)                                   AS PRIMARY_PARISH
FROM BUILDING_FLOOD_RISK
GROUP BY H3_INDEX_6
HAVING COUNT(*) >= 10
ORDER BY AVG_VULNERABILITY DESC;

-- Top 10 highest-risk hexagons
SELECT
    H3_INDEX_6, PRIMARY_PARISH, BUILDING_COUNT,
    BUILDINGS_AT_RISK, AVG_VULNERABILITY, AVG_SVI,
    TO_CHAR(TOTAL_EAL, '$999,999,999') AS TOTAL_EAL
FROM H3_FLOOD_RISK_MAP
LIMIT 10;
     


-- ============================================================
-- STEP 3.4: Critical infrastructure at flood risk
-- Hospitals, schools, fire stations in flood zones = high priority
-- ============================================================
SELECT
    CLASS,
    COUNT(*)                                                  AS TOTAL,
    COUNT(CASE WHEN IN_SPECIAL_FLOOD_HAZARD_AREA THEN 1 END)  AS IN_SFHA,
    ROUND(
        COUNT(CASE WHEN IN_SPECIAL_FLOOD_HAZARD_AREA THEN 1 END) * 100.0
        / NULLIF(COUNT(*), 0), 1
    )                                                         AS PCT_IN_SFHA,
    ROUND(AVG(COMPOSITE_VULNERABILITY_SCORE), 2)              AS AVG_VULN_SCORE,
    ROUND(AVG(SVI_OVERALL), 3)                                AS AVG_COMMUNITY_SVI
FROM BUILDING_FLOOD_RISK
WHERE CLASS IN (
    'hospital', 'clinic', 'doctors',
    'school', 'kindergarten', 'university',
    'fire_station', 'police',
    'government', 'courthouse',
    'church', 'nursing_home', 'community_centre', 'social_facility'
)
GROUP BY CLASS
ORDER BY PCT_IN_SFHA DESC NULLS LAST;
     
Lab 4: Dynamic Tables — Automated Risk Scoring Pipeline
Dynamic Tables automatically refresh when source data changes — no manual orchestration needed.
This is ideal for a production flood monitoring system where FEMA and CDC data updates regularly.

⚡ Key benefit: If FEMA publishes updated NRI scores, all downstream tables (including dashboards and alerts) automatically recalculate within the TARGET_LAG window.



-- ============================================================
-- STEP 4.1: Dynamic Table for automated flood risk alerts
-- Refreshes hourly; escalates tracts by risk level
-- ============================================================
CREATE OR REPLACE DYNAMIC TABLE FLOOD_RISK_ALERTS
  TARGET_LAG = '1 hour'
  WAREHOUSE  = FLOOD_WH
  COMMENT    = 'Auto-refreshing tract-level risk alerts for Emergency Management'
AS
SELECT
    PARISH,
    TRACTFIPS,
    COUNT(*)                                              AS BUILDINGS_AT_RISK,
    ROUND(AVG(COMPOSITE_VULNERABILITY_SCORE), 2)          AS AVG_VULNERABILITY_SCORE,
    ROUND(SUM(EAL_BUILDINGS), 0)                          AS TOTAL_BUILDING_EAL,
    ROUND(AVG(SVI_OVERALL), 3)                            AS AVG_SVI_SCORE,
    COUNT(CASE WHEN CLASS IN ('hospital','clinic','fire_station','school') THEN 1 END)
                                                          AS CRITICAL_INFRA_COUNT,
    CASE
        WHEN AVG(COMPOSITE_VULNERABILITY_SCORE) >= 70 THEN 'CRITICAL'
        WHEN AVG(COMPOSITE_VULNERABILITY_SCORE) >= 50 THEN 'HIGH'
        WHEN AVG(COMPOSITE_VULNERABILITY_SCORE) >= 30 THEN 'MODERATE'
        ELSE 'LOW'
    END                                                   AS RISK_LEVEL,
    CURRENT_TIMESTAMP()                                   AS LAST_CALCULATED
FROM BUILDING_FLOOD_RISK
WHERE IN_SPECIAL_FLOOD_HAZARD_AREA = TRUE
GROUP BY PARISH, TRACTFIPS;

-- Check alert distribution
SELECT RISK_LEVEL, COUNT(*) AS TRACT_COUNT
FROM FLOOD_RISK_ALERTS
GROUP BY RISK_LEVEL
ORDER BY TRACT_COUNT DESC;
     
/*Lab 5: Cortex AI — Policy Document Intelligence
Louisiana's 2024 State Hazard Mitigation Plan documents flood risks, levee projects, and mitigation strategies across all 64 parishes. We use Cortex PARSE_DOCUMENT to extract text and build a semantic search index.

PDF files in the workspace (data/policy_docs/):

Louisiana_Hazard_Mitigation_Plan_2024_Intro.pdf — Overview, risk assessment, Katrina/Ida impacts
Louisiana_Hazard_Mitigation_Plan_2024_Strategies.pdf — Mitigation actions, levee projects, funding
No manual upload needed — the next cell uses COPY FILES INTO to upload PDFs directly from the workspace to @FLOOD_POLICY_DOCS.
*/

-- ============================================================
-- STEP 5.1: Create stage for policy PDFs and upload documents
-- ============================================================
CREATE OR REPLACE STAGE FLOOD_POLICY_DOCS
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT    = 'Louisiana flood policy PDFs for Cortex AI analysis';

COPY FILES INTO @FLOOD_POLICY_DOCS/
FROM 'snow://workspace/USER$.PUBLIC."flood-resilience"/versions/live/'
FILES=('data/policy_docs/Louisiana_Hazard_Mitigation_Plan_2024_Intro.pdf',
       'data/policy_docs/Louisiana_Hazard_Mitigation_Plan_2024_Strategies.pdf');

ALTER STAGE FLOOD_POLICY_DOCS REFRESH;

SELECT RELATIVE_PATH, SIZE, LAST_MODIFIED
FROM DIRECTORY(@FLOOD_POLICY_DOCS)
ORDER BY LAST_MODIFIED DESC;
     


-- ============================================================
-- STEP 5.2: Parse PDFs with Cortex PARSE_DOCUMENT
-- LAYOUT mode preserves headings, paragraphs, and tables
-- ⏳ ~30-60 seconds per PDF
-- ============================================================
CREATE OR REPLACE TABLE PARSED_POLICY_DOCS AS
SELECT
    RELATIVE_PATH                       AS FILE_NAME,
    SIZE                                AS FILE_SIZE_BYTES,
    SNOWFLAKE.CORTEX.PARSE_DOCUMENT(
        @FLOOD_POLICY_DOCS,
        RELATIVE_PATH
        --,        {'mode': 'LAYOUT'}
    )                                   AS PARSED_CONTENT,
    PARSED_CONTENT:content::STRING      AS FULL_TEXT,
    CURRENT_TIMESTAMP()                 AS PARSED_AT
FROM DIRECTORY(@FLOOD_POLICY_DOCS)
WHERE RELATIVE_PATH LIKE '%.pdf';

-- Preview extracted text
SELECT
    FILE_NAME,
    FILE_SIZE_BYTES,
    LENGTH(FULL_TEXT) AS TEXT_CHARS,
    LEFT(FULL_TEXT, 500) AS TEXT_PREVIEW
FROM PARSED_POLICY_DOCS;
     


-- ============================================================
-- STEP 5.3: Chunk documents into searchable segments
-- Smaller chunks (200-800 chars) produce better vector search results
-- ============================================================
CREATE OR REPLACE TABLE POLICY_DOC_CHUNKS AS
SELECT
    FILE_NAME,
    chunk.INDEX              AS CHUNK_INDEX,
    TRIM(chunk.VALUE::STRING) AS CHUNK_TEXT,
    LENGTH(TRIM(chunk.VALUE::STRING)) AS CHUNK_LENGTH
FROM PARSED_POLICY_DOCS,
    LATERAL FLATTEN(INPUT => SPLIT(FULL_TEXT, '\n\n')) AS chunk
WHERE LENGTH(TRIM(chunk.VALUE::STRING)) > 80;

SELECT FILE_NAME, COUNT(*) AS CHUNKS, SUM(CHUNK_LENGTH) AS TOTAL_CHARS
FROM POLICY_DOC_CHUNKS
GROUP BY FILE_NAME;
     


-- ============================================================
-- STEP 5.4: Create Cortex Search service
-- Builds a semantic vector index over all policy document chunks
-- Enables hybrid keyword + semantic search
-- ============================================================
CREATE OR REPLACE CORTEX SEARCH SERVICE FLOOD_POLICY_SEARCH
  ON CHUNK_TEXT
  ATTRIBUTES FILE_NAME, CHUNK_INDEX
  WAREHOUSE  = FLOOD_WH
  TARGET_LAG = '1 day'
AS (
    SELECT CHUNK_TEXT, FILE_NAME, CHUNK_INDEX
    FROM POLICY_DOC_CHUNKS
);

-- Test semantic search — try different questions!
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'FLOOD_ANALYTICS.FLOOD.FLOOD_POLICY_SEARCH',
        '{
            "query": "What flood mitigation projects are planned for coastal Louisiana parishes?",
            "columns": ["CHUNK_TEXT", "FILE_NAME"],
            "limit": 3
        }'
    )
) AS SEARCH_RESULTS;
     


-- ============================================================
-- STEP 5.5: Cortex AI executive summary
-- Combines our structured risk data with LLM reasoning
-- ============================================================
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'llama3.1-70b',
    CONCAT(
        'You are a senior flood risk analyst for Louisiana Emergency Management. ',
        'Based on the parish-level flood risk data below, write a 3-paragraph executive summary covering:\n',
        '1. Which parishes face the highest combined flood and social vulnerability risk and why\n',
        '2. The relationship between poverty (SVI score) and flood exposure\n',
        '3. Top 3 actionable recommendations for emergency planners\n\n',
        'PARISH RISK DATA (top 15 by composite vulnerability):\n',
        (
            SELECT LISTAGG(
                PARISH || ': composite=' || AVG_COMPOSITE_SCORE ||
                ', SVI=' || AVG_SVI_SCORE ||
                ', ' || PCT_IN_SFHA || '% bldgs in flood zone' ||
                ', annual_loss=$' || TOTAL_EXPECTED_ANNUAL_LOSS,
                '\n'
            )
            FROM (
                SELECT * FROM PARISH_FLOOD_SUMMARY
                ORDER BY AVG_COMPOSITE_SCORE DESC
                LIMIT 15
            )
        )
    )
) AS EXECUTIVE_SUMMARY;
     
/*Lab 6: Cortex Analyst — Natural Language Q&A
A semantic model defines your tables in business terms, enabling Cortex Analyst to convert
natural language questions into accurate SQL queries.

Setup:

The semantic model YAML is in the repo at semantic_model/flood_risk_model.yaml
Upload it to @FLOOD_DATA_STAGE/semantic/
In Snowsight → AI & ML → Cortex Analyst → New Chat → select the YAML
Try these questions:

"Which parish has the most buildings in flood zones?"
"What is the total expected annual loss for Orleans Parish?"
"How many hospitals are in Special Flood Hazard Areas?"
"Show me parishes where SVI score is above 0.8"
"Compare coastal vs riverine flood risk by parish"
*/

-- ============================================================
-- STEP 6.1: Verify all tables exist for Cortex Analyst
-- ============================================================
SELECT
    TABLE_NAME,
    TO_CHAR(ROW_COUNT, '999,999,999')           AS ROW_COUNT_FMT,
    ROUND(BYTES / 1024.0 / 1024.0, 1) || ' MB' AS SIZE
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'FLOOD'
  AND TABLE_TYPE   = 'BASE TABLE'
ORDER BY ROW_COUNT DESC NULLS LAST;
     
/*Lab 7: Streamlit Dashboard Verification
Before deploying, verify all required tables exist. The deployment cell follows in Lab 7A.
*/

-- ============================================================
-- STEP 7.1: Final verification — all objects ready for dashboard
-- ============================================================
SELECT 'BUILDINGS_LA'         AS TABLE_NAME, COUNT(*) AS ROW_COUNT FROM BUILDINGS_LA
UNION ALL
SELECT 'FEMA_NRI',              COUNT(*) FROM FEMA_NRI
UNION ALL
SELECT 'CDC_SVI',               COUNT(*) FROM CDC_SVI
UNION ALL
SELECT 'FLOOD_ZONES',           COUNT(*) FROM FLOOD_ZONES
UNION ALL
SELECT 'BUILDING_FLOOD_RISK',   COUNT(*) FROM BUILDING_FLOOD_RISK
UNION ALL
SELECT 'PARISH_FLOOD_SUMMARY',  COUNT(*) FROM PARISH_FLOOD_SUMMARY
UNION ALL
SELECT 'H3_FLOOD_RISK_MAP',     COUNT(*) FROM H3_FLOOD_RISK_MAP
UNION ALL
SELECT 'FLOOD_RISK_ALERTS',     COUNT(*) FROM FLOOD_RISK_ALERTS
ORDER BY ROW_COUNT DESC;
     
/*Lab 7A: Deploy Streamlit Flood Dashboard
This cell automates the deployment of the interactive Streamlit dashboard directly from the workspace.

What gets deployed:

flood_dashboard.py — Main dashboard with pydeck building polygons, H3 heatmap, altair charts, and AI insights
environment.yml — Package dependencies (pydeck, altair, pandas, plotly)
.streamlit/config.toml — Snowflake brand theme (cyan buttons, clean white UI)
Dashboard features:

Pydeck PolygonLayer — actual building footprints colour-coded by vulnerability
Pydeck H3HexagonLayer — 2D hexagonal vulnerability heatmap
Altair charts — gradient bar charts, bubble scatter, histograms, donut charts
Cortex AI — ask natural-language questions about flood risk
*/

CREATE OR REPLACE STAGE FLOOD_ANALYTICS.FLOOD.STREAMLIT_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

COPY FILES INTO @FLOOD_ANALYTICS.FLOOD.STREAMLIT_STAGE/
FROM 'snow://workspace/USER$.PUBLIC."flood-resilience"/versions/live/'
FILES=('streamlit/flood_dashboard.py', 'streamlit/environment.yml', 'streamlit/.streamlit/config.toml');

CREATE OR REPLACE STREAMLIT FLOOD_ANALYTICS.FLOOD.FLOOD_VULNERABILITY_DASHBOARD
  ROOT_LOCATION  = '@FLOOD_ANALYTICS.FLOOD.STREAMLIT_STAGE/streamlit'
  MAIN_FILE      = 'flood_dashboard.py'
  QUERY_WAREHOUSE = FLOOD_WH
  TITLE          = 'Flood Vulnerability Dashboard';
     


--REPLACE THE ROLE WITH YOUR CURRENT USER ROLE 

GRANT USAGE ON DATABASE FLOOD_ANALYTICS TO ROLE ATTENDEE_ROLE;
GRANT USAGE ON SCHEMA FLOOD_ANALYTICS.FLOOD TO ROLE ATTENDEE_ROLE;
GRANT USAGE ON SCHEMA FLOOD_ANALYTICS.PUBLIC TO ROLE ATTENDEE_ROLE;
GRANT CREATE SEMANTIC VIEW ON SCHEMA FLOOD_ANALYTICS.FLOOD TO ROLE ATTENDEE_ROLE;
GRANT CREATE SEMANTIC VIEW ON SCHEMA FLOOD_ANALYTICS.PUBLIC TO ROLE ATTENDEE_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA FLOOD_ANALYTICS.FLOOD TO ROLE ATTENDEE_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA FLOOD_ANALYTICS.PUBLIC TO ROLE ATTENDEE_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA FLOOD_ANALYTICS.FLOOD TO ROLE ATTENDEE_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA FLOOD_ANALYTICS.PUBLIC TO ROLE ATTENDEE_ROLE;

-- ============================================================
-- PRIVILEGES FOR: Create Agent
-- ============================================================
GRANT CREATE AGENT ON SCHEMA FLOOD_ANALYTICS.FLOOD TO ROLE ATTENDEE_ROLE;
GRANT CREATE AGENT ON SCHEMA FLOOD_ANALYTICS.PUBLIC TO ROLE ATTENDEE_ROLE;

-- ============================================================
-- PRIVILEGES FOR: Use Semantic Views (query via Cortex Analyst)
-- ============================================================
GRANT SELECT ON ALL SEMANTIC VIEWS IN SCHEMA FLOOD_ANALYTICS.FLOOD TO ROLE ATTENDEE_ROLE;
GRANT SELECT ON ALL SEMANTIC VIEWS IN SCHEMA FLOOD_ANALYTICS.PUBLIC TO ROLE ATTENDEE_ROLE;
GRANT REFERENCES ON ALL SEMANTIC VIEWS IN SCHEMA FLOOD_ANALYTICS.FLOOD TO ROLE ATTENDEE_ROLE;
GRANT REFERENCES ON ALL SEMANTIC VIEWS IN SCHEMA FLOOD_ANALYTICS.PUBLIC TO ROLE ATTENDEE_ROLE;
GRANT SELECT ON FUTURE SEMANTIC VIEWS IN SCHEMA FLOOD_ANALYTICS.FLOOD TO ROLE ATTENDEE_ROLE;
GRANT SELECT ON FUTURE SEMANTIC VIEWS IN SCHEMA FLOOD_ANALYTICS.PUBLIC TO ATTENDEE_ROLE;
     
/*Lab 7B: Build Your Cortex Agent with Semantic Studio
Although you can run this entire lab end-to-end programmatically, we encourage you to build the Cortex Agent yourself using the Semantic Studio — Snowflake's guided, no-code agent builder built into Cortex Code.

How to Build Your Agent
Open Workspaces in Snowsight
Click Add New → select Agent and Semantic View
The Semantic Studio will guide you through creating your agent interactively
Example Prompts to Give the Agent Builder
Use these prompts when Cortex Code asks what you'd like to build:

To create the Semantic View:

"Name the semantic view "FLOOD_ANALYTICS" and locate it in FLOOD_ANALYTICS.FLOOD. Use all 12 tables in the FLOOD_ANALYTICS.FLOOD schema, and exclude the dynamic table."

To create the agent:

"Create an agent called FLOOD_RISK_AGENT in FLOOD_ANALYTICS.FLOOD that combines structured flood data with unstructured policy documents. It should use my semantic view for querying 3.5M Louisiana buildings with risk scores, and a Cortex Search service for searching the Louisiana Hazard Mitigation Plan PDFs."

To add the structured data tool (Semantic View):

"Add a semantic view tool pointing to FLOOD_ANALYTICS.FLOOD.FLOOD_RISK_SEMANTIC_VIEW. This covers buildings, parishes, FEMA risk scores, CDC social vulnerability, and flood zone designations."

To add the unstructured data tool (Cortex Search):

"Add a Cortex Search tool using the FLOOD_POLICY_SEARCH service in FLOOD_ANALYTICS.FLOOD. It searches Louisiana's 2024 State Hazard Mitigation Plan for mitigation strategies, levee projects, and policy recommendations."

To set instructions:

"Set the agent instructions to: You are a Louisiana flood risk analyst. Use query_flood_data for building counts, parish comparisons, vulnerability scores, and risk statistics. Use search_policy_docs for mitigation plans, historical disasters, levee projects, and government programs. For comprehensive answers, use both tools. Provide concise, data-driven answers with clear formatting."

To deploy and test:

"Deploy the agent and test it with: Which 5 parishes have the highest flood vulnerability?"

Try These Questions Once Your Agent is Deployed
Question	What Happens
"Which 5 parishes have the highest flood vulnerability?"	Agent queries your structured data
"What does the state plan say about levee projects?"	Agent searches the policy PDFs
"Which parishes are most at risk and what federal programs can help?"	Agent uses BOTH tools
"What happened during Hurricane Katrina?"	Agent searches policy docs for history
"Compare social vulnerability of Orleans vs Jefferson Parish"	Agent generates SQL comparison
Tip: After deploying, go to AI & ML → Snowflake Intelligence to chat with your agent in a full conversational UI.

Lab 7B: Deploy Cortex Agent (Structured + Unstructured Q&A)
This is the alternate lab journey. In case you are not able to build the agent yourself. You can change the cell below from markdown to SQL and then run it.

The Cortex Agent is the most powerful interface in this lab. It combines:

Structured data (3.56M buildings, risk scores, parish statistics) via Cortex Analyst
Unstructured policy documents (Louisiana Hazard Mitigation Plan) via Cortex Search
This means you can ask questions like "Which parishes are most at risk and what does the state plan say about helping them?" — and get a unified answer from both data AND documents.

How to deploy:
Run the cell below to create the agent
In Snowsight → AI & ML → Snowflake Intelligence → select FLOOD_RISK_AGENT
Start asking questions!
Try these questions:
Question	What happens
"Which 5 parishes have the highest flood vulnerability?"	Agent queries your structured data
"What does the state plan say about levee projects?"	Agent searches the policy PDFs
"Which parishes are most at risk and what federal programs can help?"	Agent uses BOTH tools
"What happened during Hurricane Katrina?"	Agent searches policy docs for history
"Compare social vulnerability of Orleans vs Jefferson Parish"	Agent generates SQL comparison

*/
-- ============================================================ -- STEP 7B: Create Cortex Agent (Structured + Unstructured) -- Combines Cortex Analyst (SQL) + Cortex Search (policy docs) -- ============================================================ COPY FILES INTO @FLOOD_ANALYTICS.FLOOD.FLOOD_DATA_STAGE/semantic/ FROM 'snow://workspace/USER$.PUBLIC."flood-resilience"/versions/live/' FILES=('semantic_model/flood_risk_model.yaml');

CREATE OR REPLACE AGENT FLOOD_ANALYTICS.FLOOD.FLOOD_RISK_AGENT FROM SPECIFICATION
;

SHOW AGENTS IN SCHEMA FLOOD_ANALYTICS.FLOOD;

/*Next step: Go to Snowsight → AI & ML → Snowflake Intelligence → select FLOOD_RISK_AGENT and try the questions above!

The agent will automatically decide whether to query your structured data, search policy documents, or combine both — based on your question.

Lab 7C: Register Agent in Snowflake Intelligence
This is the alternate lab journey. In case you are not able to build the agent yourself. You can change the cell below from markdown to SQL and then run it.

Make the Cortex Agent accessible from the Snowflake Intelligence UI so users can interact with it conversationally.
*/

CREATE SNOWFLAKE INTELLIGENCE IF NOT EXISTS SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT;

ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT ADD AGENT FLOOD_ANALYTICS.FLOOD.FLOOD_RISK_AGENT;

SELECT 'Agent registered in Snowflake Intelligence' AS STATUS;

/*Lab 8: Cleanup (Optional)
⚠️ Only run if you're finished with the lab and want to release resources.
*/

-- ============================================================
-- STEP 8.1: Cleanup — removes all lab objects
-- ⚠️ UNCOMMENT ONLY WHEN DONE WITH THE ENTIRE LAB
-- ============================================================

-- DROP DATABASE IF EXISTS FLOOD_ANALYTICS;
-- DROP WAREHOUSE IF EXISTS FLOOD_WH;

/*SELECT 'Cleanup skipped. Uncomment lines above when ready.' AS STATUS;
     
🎉 Congratulations — Lab Complete!
Lab	What You Built	Snowflake Feature
1	3M+ Louisiana buildings from Overture Maps	Marketplace + Geospatial + H3
2	FEMA NRI + CDC SVI data pipeline	Internal Stages + COPY INTO
3	Building-level flood risk cross-reference	H3 Indexing + SQL Analytics
4	Auto-refreshing risk alert pipeline	Dynamic Tables
5	PDF parsing + semantic document search	Cortex PARSE_DOCUMENT + Cortex Search
6	Natural-language flood risk Q&A	Cortex Analyst + Semantic Model
7	Interactive vulnerability dashboard	Streamlit in Snowflake
🚀 What's Next?
Scale to 50 states — remove the Louisiana bounding box filter
Add real-time USGS stream gauge data from the Snowflake Marketplace
Integrate NOAA hurricane track forecasts for predictive risk
Use exact tract-boundary polygons with ST_WITHIN() for precise building assignment
Add the National Levee Database for defended vs undefended flood zone analysis*/
