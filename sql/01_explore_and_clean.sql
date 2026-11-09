-- Maji Ndogo water services | Part 1: Beginning our data-driven journey
-- Database: md_water_services (MySQL)
-- Context: the survey produced 60,000 records. Before any analysis,
-- we need to understand the structure of the data and check its
-- quality. This script covers the exploration and the first cleaning.
-- Sections:
--   1. Surveying the landscape (tables and structure)
--   2. Understanding water sources
--   3. Analyzing the visits logbook
--   4. Auditing data quality
--   5. Investigating well pollution and fixing the errors
-- ============================================================

-- 1. Surveying the landscape

-- List every table in the database (8 tables)
SHOW TABLES;

-- Preview the first five rows of the core tables to see their columns
-- location: where each source is (address, province, town, urban or rural)
SELECT * FROM location LIMIT 5;
-- visits: logbook of every trip made to a water source
SELECT * FROM visits LIMIT 5;
-- water_source: the type of each source and how many people it serves
SELECT * FROM water_source LIMIT 5;


-- ------------------------------------------------------------
-- 2. Understanding water sources
-- ------------------------------------------------------------

-- Which types of water source exist in the data?
SELECT DISTINCT type_of_water_source FROM water_source;

/* Key findings:
River: Open water source with high contamination risk.
Well: Underground source, safer but vulnerable to aging infrastructure.
Shared Tap: Serves large communities, often resulting in long wait times.
Tap in Home: Provides private, convenient access to water.
Broken Tap in Home: Installed infrastructure that is no longer functional.
*/


-- ------------------------------------------------------------
-- 3. Analyzing the visits logbook
-- ------------------------------------------------------------

-- Find visits where people queued for more than 500 minutes (over 8 hours).
-- These are extreme values worth investigating.
SELECT * FROM visits WHERE time_in_queue > 500;

-- Which sources have these extreme wait times?
-- visits only holds the source_id, so join water_source to see the type.
-- Result: the long queues are at shared taps.
SELECT
    ws.*
FROM
    water_source AS ws
JOIN
    visits AS v
    ON ws.source_id = v.source_id
WHERE
    v.time_in_queue > 500;


-- ------------------------------------------------------------
-- 4. Auditing data quality
-- ------------------------------------------------------------

-- Surveyors only made repeat visits to shared taps, so a home tap
-- that scored 10 should never have a second visit.
-- Check: home taps with a perfect quality score and more than one visit.
-- Any rows returned point to errors in the survey data. This returns
-- 218 rows, which is why an independent auditor is brought in later
-- in the project.
-- Join path: water_quality -> visits (record_id) -> water_source (source_id)
SELECT
    wq.record_id,
    ws.type_of_water_source,
    wq.subjective_quality_score
FROM
    water_quality AS wq
JOIN
    visits AS v
    ON wq.record_id = v.record_id
JOIN
    water_source AS ws
    ON ws.source_id = v.source_id
WHERE
    wq.subjective_quality_score = 10
    AND ws.type_of_water_source = 'tap_in_home'
    AND v.visit_count > 1;


-- ------------------------------------------------------------
-- 5. Investigating well pollution
-- ------------------------------------------------------------
-- Problem 1: 38 descriptions start with 'Clean' even though bacteria
-- were found (for example 'Clean Bacteria: E. coli'). Only wells with no
-- contamination should be described as 'Clean'.
-- Problem 2: some wells are marked 'Clean' in the results column even
-- though the biological contamination is above the 0.01 CFU/mL threshold.
-- Contamination marked as clean is the worst case, because people can
-- get sick.

-- Step 1: Create a backup table
-- Test the fixes on a copy first, so a mistake cannot damage the original.
CREATE TABLE well_pollution_copy AS (SELECT * FROM well_pollution);

-- Step 2: Clean descriptions
-- Safe update mode blocks UPDATEs that filter on non-key columns,
-- so it is switched off for this session and turned back on at the end.
SET SQL_SAFE_UPDATES = 0;

-- Case 1a: 'Clean Bacteria: E. coli' becomes 'Bacteria: E. coli'
UPDATE well_pollution_copy
SET description = 'Bacteria: E. coli'
WHERE description = 'Clean Bacteria: E. coli';

-- Case 1b: 'Clean Bacteria: Giardia Lamblia' becomes 'Bacteria: Giardia Lamblia'
UPDATE well_pollution_copy
SET description = 'Bacteria: Giardia Lamblia'
WHERE description = 'Clean Bacteria: Giardia Lamblia';

-- Step 3: Fix contamination status
-- Case 2: wells marked 'Clean' with biological contamination above 0.01
-- are reclassified as 'Contaminated: Biological'
UPDATE well_pollution_copy
SET results = 'Contaminated: Biological'
WHERE biological > 0.01 AND results = 'Clean';

-- Step 4: Copy the corrected data back to the original table
-- and remove the backup
TRUNCATE TABLE well_pollution;
INSERT INTO well_pollution
SELECT * FROM well_pollution_copy;
DROP TABLE well_pollution_copy;

-- Turn safe update mode back on
SET SQL_SAFE_UPDATES = 1;