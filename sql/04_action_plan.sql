-- ============================================================
-- Maji Ndogo water services | Part 4: From analysis to action
-- Database: md_water_services (MySQL)
--
-- Context: the investigation is done. This script turns the data into a
-- plan: one flat view for analysis, a pivot by province and by town to
-- see where the problems are, and a Project_progress table that gives
-- the repair engineers a job list and a place to report progress.
--
-- Table aliases used throughout:
--   combined_analysis_table AS cat | town_aggregated_water_access AS taw
--   water_source AS ws | well_pollution AS wp | visits AS v | location AS l
--
-- Steps:
--   1. Combined analysis view (NEW VIEW)
--   2. Provincial pivot: how each province gets its water
--   3. Town pivot, stored as a temporary table (NEW TEMPORARY TABLE)
--   4. Reading the town table
--   5. Project_progress: the engineers' tracker (NEW TABLE)
--   6. Choosing which sources need work
--   7. Writing the improvement for each source
--   8. Filling Project_progress
--   9. Key findings
--
-- Note: no existing data is changed in this part. The new objects are
-- the combined_analysis_table view, the town_aggregated_water_access
-- temporary table and the Project_progress table.
-- ============================================================

USE md_water_services;


-- ------------------------------------------------------------
-- 1. Combined analysis view
-- ------------------------------------------------------------
-- Joining many tables for every question gets slow on 60,000 records,
-- so the data needed for the analysis is assembled once into a view.
-- visits is the bridge between location and water_source.
-- visit_count = 1 removes repeat visits to the same source.
-- well_pollution only holds wells, so it is a LEFT JOIN: every other
-- source type keeps its row, with results = NULL.
CREATE OR REPLACE VIEW combined_analysis_table AS
SELECT
    ws.type_of_water_source AS source_type,
    l.town_name,
    l.province_name,
    l.location_type,
    ws.number_of_people_served AS people_served,
    v.time_in_queue,
    wp.results
FROM
    visits AS v
LEFT JOIN
    well_pollution AS wp
    ON wp.source_id = v.source_id
JOIN
    location AS l
    ON l.location_id = v.location_id
JOIN
    water_source AS ws
    ON ws.source_id = v.source_id
WHERE
    v.visit_count = 1;

-- Check: one row per source, so the two counts are equal (39,650)
SELECT COUNT(*) FROM combined_analysis_table;
SELECT COUNT(*) FROM water_source;
-- results is NULL for every source type except wells
SELECT * FROM combined_analysis_table LIMIT 10;


-- ------------------------------------------------------------
-- 2. Provincial pivot
-- ------------------------------------------------------------
-- What share of each province's population uses each type of source?
-- The CTE holds the population of each province (the 100% base). Each
-- CASE column sums the people on one source type and turns it into a
-- percentage of that total.
WITH province_totals AS (
    SELECT
        cat.province_name,
        SUM(cat.people_served) AS total_ppl_serv
    FROM
        combined_analysis_table AS cat
    GROUP BY cat.province_name
)
SELECT
    cat.province_name,
    ROUND(SUM(CASE WHEN cat.source_type = 'river'
        THEN cat.people_served ELSE 0 END) * 100.0 / pt.total_ppl_serv, 0) AS river,
    ROUND(SUM(CASE WHEN cat.source_type = 'shared_tap'
        THEN cat.people_served ELSE 0 END) * 100.0 / pt.total_ppl_serv, 0) AS shared_tap,
    ROUND(SUM(CASE WHEN cat.source_type = 'tap_in_home'
        THEN cat.people_served ELSE 0 END) * 100.0 / pt.total_ppl_serv, 0) AS tap_in_home,
    ROUND(SUM(CASE WHEN cat.source_type = 'tap_in_home_broken'
        THEN cat.people_served ELSE 0 END) * 100.0 / pt.total_ppl_serv, 0) AS tap_in_home_broken,
    ROUND(SUM(CASE WHEN cat.source_type = 'well'
        THEN cat.people_served ELSE 0 END) * 100.0 / pt.total_ppl_serv, 0) AS well
FROM
    combined_analysis_table AS cat
JOIN
    province_totals AS pt
    ON cat.province_name = pt.province_name
GROUP BY
    cat.province_name
ORDER BY
    cat.province_name;
-- Each row adds up to about 100 (three provinces give 100, two give 101,
-- because every column is rounded to a whole number).
-- Sokoto has the highest river share: drilling teams go there first.
-- Amanzi has many home taps but about half of them are broken: engineers
-- go there first.


-- ------------------------------------------------------------
-- 3. Town pivot, stored as a temporary table
-- ------------------------------------------------------------
-- Same pivot, one level down. Town names are not unique (there are two
-- Harare and two Amina towns, in different provinces), so the totals and
-- the join use province_name AND town_name together.
-- The result is saved as a temporary table because the query is slow and
-- every later question only needs a simple SELECT on it.
-- A temporary table disappears when the connection closes: run this block
-- again after reconnecting.
DROP TEMPORARY TABLE IF EXISTS town_aggregated_water_access;

CREATE TEMPORARY TABLE town_aggregated_water_access AS
WITH town_totals AS ( -- people served per town (the 100% base)
    SELECT
        cat.province_name,
        cat.town_name,
        SUM(cat.people_served) AS total_ppl_serv
    FROM
        combined_analysis_table AS cat
    GROUP BY cat.province_name, cat.town_name
)
SELECT
    cat.province_name,
    cat.town_name,
    ROUND(SUM(CASE WHEN cat.source_type = 'tap_in_home'
        THEN cat.people_served ELSE 0 END) * 100.0 / tt.total_ppl_serv, 0) AS tap_in_home,
    ROUND(SUM(CASE WHEN cat.source_type = 'tap_in_home_broken'
        THEN cat.people_served ELSE 0 END) * 100.0 / tt.total_ppl_serv, 0) AS tap_in_home_broken,
    ROUND(SUM(CASE WHEN cat.source_type = 'shared_tap'
        THEN cat.people_served ELSE 0 END) * 100.0 / tt.total_ppl_serv, 0) AS shared_tap,
    ROUND(SUM(CASE WHEN cat.source_type = 'well'
        THEN cat.people_served ELSE 0 END) * 100.0 / tt.total_ppl_serv, 0) AS well,
    ROUND(SUM(CASE WHEN cat.source_type = 'river'
        THEN cat.people_served ELSE 0 END) * 100.0 / tt.total_ppl_serv, 0) AS river
FROM
    combined_analysis_table AS cat
JOIN
    town_totals AS tt
    ON cat.province_name = tt.province_name
    AND cat.town_name = tt.town_name -- composite key, town names repeat
GROUP BY
    cat.province_name,
    cat.town_name,
    tt.total_ppl_serv; -- MySQL asks for this when joining on two keys

-- Check: 31 rows, one per province and town pair
SELECT COUNT(*) FROM town_aggregated_water_access;
SELECT * FROM town_aggregated_water_access ORDER BY province_name, town_name;


-- ------------------------------------------------------------
-- 4. Reading the town table
-- ------------------------------------------------------------
-- 4a. Where do people drink river water? Highest share first.
SELECT
    taw.province_name,
    taw.town_name,
    taw.river
FROM
    town_aggregated_water_access AS taw
ORDER BY
    taw.river DESC;
-- Top three: Sokoto Rural (22%), Sokoto Bahari (21%), Sokoto Kofi (20%).

-- 4b. Amina in Amanzi: working versus broken home taps.
SELECT
    taw.province_name,
    taw.town_name,
    taw.tap_in_home,
    taw.tap_in_home_broken
FROM
    town_aggregated_water_access AS taw
WHERE
    taw.town_name = 'Amina'
    AND taw.province_name = 'Amanzi';
-- Result: 3% working, 56% broken.

-- 4c. Which towns have the highest share of broken home taps?
-- Of the people with a home tap, what percent have a broken one?
-- NULLIF avoids a divide by zero in a town with no home taps at all.
SELECT
    taw.province_name,
    taw.town_name,
    ROUND(
        taw.tap_in_home_broken * 100.0
        / NULLIF(taw.tap_in_home_broken + taw.tap_in_home, 0)
    , 0) AS pct_broken_taps
FROM
    town_aggregated_water_access AS taw
ORDER BY
    pct_broken_taps DESC;
-- Top three: Amanzi Amina (95%), Kilimani Zuri (65%), Hawassa Amina (56%).
-- Hawassa Amina is a different town from Amanzi Amina, which is why the
-- province is always part of the filter.


-- ------------------------------------------------------------
-- 5. Project_progress: the engineers' tracker
-- ------------------------------------------------------------
-- A table where the repair teams can see which source to visit, what to
-- do there, and report back when it is done.
-- Design choices:
--   Project_id    unique job number, in case a source is visited again
--   source_id     must exist in water_source (FOREIGN KEY). The
--                 constraint is written explicitly, because MySQL
--                 ignores a REFERENCES placed inside a column definition.
--   Source_status limited with CHECK to three values, default 'Backlog'
--   Date_of_completion and Comments are filled in by the engineers
DROP TABLE IF EXISTS Project_progress;

CREATE TABLE Project_progress (
    Project_id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    source_id VARCHAR(20) NOT NULL,
    Address VARCHAR(50),
    Town VARCHAR(30),
    Province VARCHAR(30),
    Source_type VARCHAR(50),
    Improvement VARCHAR(50),
    Source_status VARCHAR(50) DEFAULT 'Backlog'
        CHECK (Source_status IN ('Backlog', 'In progress', 'Complete')),
    Date_of_completion DATE,
    Comments TEXT,
    CONSTRAINT fk_project_source
        FOREIGN KEY (source_id) REFERENCES water_source (source_id)
        ON DELETE CASCADE ON UPDATE CASCADE
);

SHOW CREATE TABLE Project_progress;


-- ------------------------------------------------------------
-- 6. Choosing which sources need work
-- ------------------------------------------------------------
-- The view has no source_id or address, which the engineers need, so this
-- query starts again from the base tables.
-- Rules for including a source:
--   visit_count = 1 always, then ANY of:
--   a) a well that is not clean
--   b) a river or a broken home tap
--   c) a shared tap with a queue of 30 minutes or more (UN guideline)
-- Result: 25,398 rows.
SELECT
    l.address,
    l.town_name,
    l.province_name,
    ws.source_id,
    ws.type_of_water_source,
    wp.results
FROM
    water_source AS ws
LEFT JOIN
    well_pollution AS wp
    ON ws.source_id = wp.source_id
JOIN
    visits AS v
    ON ws.source_id = v.source_id
JOIN
    location AS l
    ON l.location_id = v.location_id
WHERE
    v.visit_count = 1
    AND (
        wp.results != 'Clean'
        OR ws.type_of_water_source IN ('tap_in_home_broken', 'river')
        OR (ws.type_of_water_source = 'shared_tap'
            AND v.time_in_queue >= 30)
    );


-- ------------------------------------------------------------
-- 7. Writing the improvement for each source
-- ------------------------------------------------------------
-- CASE uses the first WHEN that matches:
--   chemical contamination   -> reverse osmosis (RO) filter
--   biological contamination -> UV filter (kills microorganisms) plus RO
--   river                    -> drill a well nearby
--   shared tap, 30+ minutes  -> one extra tap per 30 minutes of queue.
--                               FLOOR rounds down: 30 to 59 minutes means
--                               1 tap, 60 to 89 means 2, and so on.
--   broken home tap          -> diagnose the local infrastructure, because
--                               one repair can restore many homes
-- Still 25,398 rows, and no NULL values in Improvement.
SELECT
    l.address,
    l.town_name,
    l.province_name,
    ws.source_id,
    ws.type_of_water_source,
    CASE
        WHEN wp.results = 'Contaminated: Chemical'   THEN 'Install RO filter'
        WHEN wp.results = 'Contaminated: Biological' THEN 'Install UV and RO filter'
        WHEN ws.type_of_water_source = 'river'       THEN 'Drill well'
        WHEN ws.type_of_water_source = 'shared_tap'
             AND v.time_in_queue >= 30
            THEN CONCAT('Install ', FLOOR(v.time_in_queue / 30), ' taps nearby')
        WHEN ws.type_of_water_source = 'tap_in_home_broken'
            THEN 'Diagnose local infrastructure'
        ELSE NULL
    END AS Improvement
FROM
    water_source AS ws
LEFT JOIN
    well_pollution AS wp
    ON ws.source_id = wp.source_id
JOIN
    visits AS v
    ON ws.source_id = v.source_id
JOIN
    location AS l
    ON l.location_id = v.location_id
WHERE
    v.visit_count = 1
    AND (
        wp.results != 'Clean'
        OR ws.type_of_water_source IN ('tap_in_home_broken', 'river')
        OR (ws.type_of_water_source = 'shared_tap'
            AND v.time_in_queue >= 30)
    );


-- ------------------------------------------------------------
-- 8. Filling Project_progress
-- ------------------------------------------------------------
-- Same query with INSERT INTO on top. The SELECT columns must be in the
-- same order as the column list. Source_status is left out, so every job
-- starts as 'Backlog'.
-- Run this ONCE: source_id is not unique in the table, so a second run
-- would add every row again. To redo it: TRUNCATE TABLE Project_progress;
INSERT INTO Project_progress (source_id, Address, Town, Province, Source_type, Improvement)
SELECT
    ws.source_id,
    l.address,
    l.town_name,
    l.province_name,
    ws.type_of_water_source,
    CASE
        WHEN wp.results = 'Contaminated: Chemical'   THEN 'Install RO filter'
        WHEN wp.results = 'Contaminated: Biological' THEN 'Install UV and RO filter'
        WHEN ws.type_of_water_source = 'river'       THEN 'Drill well'
        WHEN ws.type_of_water_source = 'shared_tap'
             AND v.time_in_queue >= 30
            THEN CONCAT('Install ', FLOOR(v.time_in_queue / 30), ' taps nearby')
        WHEN ws.type_of_water_source = 'tap_in_home_broken'
            THEN 'Diagnose local infrastructure'
        ELSE NULL
    END AS Improvement
FROM
    water_source AS ws
LEFT JOIN
    well_pollution AS wp
    ON ws.source_id = wp.source_id
JOIN
    visits AS v
    ON ws.source_id = v.source_id
JOIN
    location AS l
    ON l.location_id = v.location_id
WHERE
    v.visit_count = 1
    AND (
        wp.results != 'Clean'
        OR ws.type_of_water_source IN ('tap_in_home_broken', 'river')
        OR (ws.type_of_water_source = 'shared_tap'
            AND v.time_in_queue >= 30)
    );

-- Check 1: 25,398 rows
SELECT COUNT(*) FROM Project_progress;

-- Check 2: every job starts as Backlog
SELECT Source_status, COUNT(*) AS jobs
FROM Project_progress
GROUP BY Source_status;

-- Check 3: size of the plan by source type
SELECT Source_type, COUNT(*) AS jobs
FROM Project_progress
GROUP BY Source_type
ORDER BY jobs DESC;
-- well 12,467 | tap_in_home_broken 5,856 | shared_tap 3,696 | river 3,379

-- How engineers will report progress (example only, not run here):
-- UPDATE Project_progress
-- SET Source_status = 'Complete',
--     Date_of_completion = '2026-11-20',
--     Comments = 'RO filter installed'
-- WHERE Project_id = 1;


/* Key findings:
- The action plan covers 25,398 sources out of 39,650 (64%). The rest
  are clean wells, working home taps, and shared taps with short queues.
- By number of jobs, wells are the biggest workload: 12,467 jobs (49%),
  mostly filters. Next come broken home taps (5,856, 23%), shared taps
  with long queues (3,696, 15%) and rivers (3,379, 13%).
- The number of jobs is not the same as the number of people helped.
  Shared taps are only 15% of the jobs but serve the most people (43% of
  the population), so they come first in the plan.
- Sokoto has the highest river dependency. Rural Sokoto, Bahari and Kofi
  are the three towns with the most people on river water, so drilling
  crews start there while tankers cover the gap.
- Amina in Amanzi has 95% of its home taps broken. Fixing the system
  behind them restores water to homes and also shortens the queues,
  because fewer people need the shared taps.
- Most sources are rural, so every job in the plan means long distances,
  poor roads and limited supplies. The teams need to plan for it.
- Project_progress gives the engineers one row per job, and the status
  and completion date make the plan trackable, for example in Power BI.
*/