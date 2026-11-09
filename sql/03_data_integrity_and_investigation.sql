-- ============================================================
-- Maji Ndogo water services | Part 3: Data integrity and investigation
-- Database: md_water_services (MySQL)
--
-- Context: an independent auditor re-checked 1,620 sites and sent back
-- a report. This script compares the auditor's scores with the
-- surveyors' scores, checks whether earlier results are still valid,
-- and traces the errors back to the employees who recorded them.
--
-- Table aliases used throughout:
--   auditor_report AS ar | visits AS v | water_quality AS wq
--   water_source AS ws   | employee AS e
--
-- Steps:
--   0. Setup: the ERD and the auditor_report table
--   1. Integrating the auditor's report
--   2. Checking the source types
--   3. Linking incorrect records to employees
--   4. Finding employees with above-average mistakes
--   5. Gathering evidence from the statements
--
-- Note: nothing in the survey tables is changed in this part.
-- The only new objects are the auditor_report table and the
-- Incorrect_records view.
-- ============================================================

USE md_water_services;


-- ------------------------------------------------------------
-- 0. Setup
-- ------------------------------------------------------------

-- ERD: generated in MySQL Workbench with Database > Reverse Engineer.
-- visits is the central table. location_id, source_id and
-- assigned_employee_id are primary keys in their own tables and foreign
-- keys in visits (one-to-many: one location can have many visits).
-- The relationship between visits and water_quality was changed to
-- one-to-one in the diagram, because every visit has exactly one quality
-- record. Both record_id columns were first checked to be unique.
SELECT record_id, COUNT(*) FROM visits GROUP BY record_id HAVING COUNT(*) > 1;
SELECT record_id, COUNT(*) FROM water_quality GROUP BY record_id HAVING COUNT(*) > 1;
-- Both return no rows.

-- Auditor report table, then the CSV was loaded with the Workbench
-- Table Data Import Wizard (1,620 rows, one per re-visited site)
DROP TABLE IF EXISTS `auditor_report`;

CREATE TABLE `auditor_report` (
    `location_id` VARCHAR(32),
    `type_of_water_source` VARCHAR(64),
    `true_water_source_score` INT DEFAULT NULL,
    `statements` VARCHAR(255)
);

-- Check the import
SELECT COUNT(*) FROM auditor_report; -- 1,620 rows


-- ------------------------------------------------------------
-- 1. Integrating the auditor's report
-- ------------------------------------------------------------
-- Question 1: is there a difference between the scores?
-- The auditor report uses location_id, but water_quality only has
-- record_id. visits holds both, so it is the bridge between them.

-- Join the auditor report to visits to get the record_id of each site
SELECT
    ar.location_id AS audit_location,
    ar.true_water_source_score,
    v.location_id AS visit_location,
    v.record_id
FROM
    auditor_report AS ar
JOIN
    visits AS v
    ON ar.location_id = v.location_id;

-- Add the surveyors' scores from water_quality
SELECT
    ar.location_id AS audit_location,
    ar.true_water_source_score,
    v.location_id AS visit_location,
    v.record_id,
    wq.subjective_quality_score
FROM
    auditor_report AS ar
JOIN
    visits AS v
    ON ar.location_id = v.location_id
JOIN
    water_quality AS wq
    ON v.record_id = wq.record_id;
-- Returns 2,505 rows: some locations were visited more than once,
-- so their records appear several times.

-- Clean up: one location_id column, clear score names, and first visits
-- only (visit_count = 1) to remove the duplicates.
-- Returns 1,620 rows, one per site the auditor checked.
SELECT
    ar.location_id,
    v.record_id,
    ar.true_water_source_score AS auditor_score,
    wq.subjective_quality_score AS employee_score
FROM
    auditor_report AS ar
JOIN
    visits AS v
    ON ar.location_id = v.location_id
JOIN
    water_quality AS wq
    ON v.record_id = wq.record_id
WHERE
    v.visit_count = 1
LIMIT 10000;

-- Records where the auditor and the surveyor agree: 1,518 rows
SELECT
    ar.location_id,
    v.record_id,
    ar.true_water_source_score AS auditor_score,
    wq.subjective_quality_score AS employee_score
FROM
    auditor_report AS ar
JOIN
    visits AS v
    ON ar.location_id = v.location_id
JOIN
    water_quality AS wq
    ON v.record_id = wq.record_id
WHERE
    v.visit_count = 1
    AND ar.true_water_source_score = wq.subjective_quality_score
LIMIT 10000;

-- Records where they disagree: 102 rows (1,518 of 1,620 = 94% correct)
SELECT
    ar.location_id,
    v.record_id,
    ar.true_water_source_score AS auditor_score,
    wq.subjective_quality_score AS employee_score
FROM
    auditor_report AS ar
JOIN
    visits AS v
    ON ar.location_id = v.location_id
JOIN
    water_quality AS wq
    ON v.record_id = wq.record_id
WHERE
    v.visit_count = 1
    AND ar.true_water_source_score != wq.subjective_quality_score
LIMIT 10000;


-- ------------------------------------------------------------
-- 2. Checking the source types
-- ------------------------------------------------------------
-- The earlier analysis relied on type_of_water_source, not on the scores.
-- Compare the source type in the survey with the one the auditor found
-- for the 102 incorrect records.
SELECT
    ar.location_id,
    ar.type_of_water_source AS auditor_source,
    ws.type_of_water_source AS survey_source,
    v.record_id,
    ar.true_water_source_score AS auditor_score,
    wq.subjective_quality_score AS employee_score
FROM
    auditor_report AS ar
JOIN
    visits AS v
    ON ar.location_id = v.location_id
JOIN
    water_quality AS wq
    ON v.record_id = wq.record_id
JOIN
    water_source AS ws
    ON ws.source_id = v.source_id
WHERE
    v.visit_count = 1
    AND ar.true_water_source_score != wq.subjective_quality_score
LIMIT 10000;
-- The two source columns match on every row, so the wrong scores do not
-- affect the source type analysis from Part 2. The water_source join is
-- not needed after this check and is left out of the next queries.


-- ------------------------------------------------------------
-- 3. Linking incorrect records to employees
-- ------------------------------------------------------------
-- Errors come from either honest mistakes or deliberate wrong scoring.
-- In both cases the employee who recorded the visit is the source, so
-- join employee through assigned_employee_id.

-- Saved as a VIEW because the query is long and used in every later step.
-- Incorrect_records = the 102 records where the auditor's score and the
-- surveyor's score are different, with the employee who recorded each one.
CREATE OR REPLACE VIEW Incorrect_records AS (
    SELECT
        ar.location_id,
        v.record_id,
        e.employee_name,
        ar.true_water_source_score AS auditor_score,
        wq.subjective_quality_score AS employee_score,
        ar.statements AS statements
    FROM
        auditor_report AS ar
    JOIN
        visits AS v
        ON ar.location_id = v.location_id
    JOIN
        water_quality AS wq
        ON v.record_id = wq.record_id
    JOIN
        employee AS e
        ON e.assigned_employee_id = v.assigned_employee_id
    WHERE
        v.visit_count = 1
        AND ar.true_water_source_score != wq.subjective_quality_score
);

-- Check: returns the same 102 records
SELECT * FROM Incorrect_records;

-- Unique employees with at least one incorrect record: 17
SELECT DISTINCT
    ir.employee_name
FROM
    Incorrect_records AS ir;


-- ------------------------------------------------------------
-- 4. Finding employees with above-average mistakes
-- ------------------------------------------------------------
-- Everyone makes some mistakes. Someone acting on purpose would make
-- more than average, so count the mistakes per employee first.
WITH error_count AS ( -- number of mistakes each employee made
    SELECT
        ir.employee_name,
        COUNT(ir.employee_name) AS number_of_mistakes
    FROM
        Incorrect_records AS ir
        /* Incorrect_records is a view that joins the audit report to the
        database for records where the auditor and employee scores differ */
    GROUP BY ir.employee_name
)
SELECT
    ec.employee_name,
    ec.number_of_mistakes
FROM
    error_count AS ec
ORDER BY ec.number_of_mistakes DESC;

-- Employees with an above-average number of mistakes (the suspect list).
-- The average is a subquery because an aggregate cannot be used in WHERE.
WITH error_count AS (
    SELECT
        ir.employee_name,
        COUNT(ir.employee_name) AS number_of_mistakes
    FROM
        Incorrect_records AS ir
    GROUP BY ir.employee_name
)
SELECT
    ec.employee_name,
    ec.number_of_mistakes
FROM
    error_count AS ec
WHERE
    ec.number_of_mistakes > (SELECT AVG(ec2.number_of_mistakes) FROM error_count AS ec2);
-- Four employees: Bello Azibo (26), Malachi Mavuso (21),
-- Zuriel Matembo (17) and Lalitha Kaburi (7)


-- ------------------------------------------------------------
-- 5. Gathering evidence from the statements
-- ------------------------------------------------------------
-- Above-average mistakes alone could just mean someone is careless.
-- The auditor also recorded what locals said about each site, so look
-- at the statements for the four employees on the suspect list.
WITH error_count AS ( -- number of mistakes each employee made
    SELECT
        ir.employee_name,
        COUNT(ir.employee_name) AS number_of_mistakes
    FROM
        Incorrect_records AS ir
    GROUP BY ir.employee_name
),
suspect_list AS ( -- employees with above-average mistakes
    SELECT
        ec.employee_name,
        ec.number_of_mistakes
    FROM
        error_count AS ec
    WHERE
        ec.number_of_mistakes > (SELECT AVG(ec2.number_of_mistakes) FROM error_count AS ec2)
)
-- All records gathered by the suspects, with the statements about them
SELECT
    ir.employee_name,
    ir.location_id,
    ir.statements
FROM
    Incorrect_records AS ir
WHERE
    ir.employee_name IN (SELECT sl.employee_name FROM suspect_list AS sl);

-- Same query, filtered to statements that mention "cash"
WITH error_count AS (
    SELECT
        ir.employee_name,
        COUNT(ir.employee_name) AS number_of_mistakes
    FROM
        Incorrect_records AS ir
    GROUP BY ir.employee_name
),
suspect_list AS (
    SELECT
        ec.employee_name,
        ec.number_of_mistakes
    FROM
        error_count AS ec
    WHERE
        ec.number_of_mistakes > (SELECT AVG(ec2.number_of_mistakes) FROM error_count AS ec2)
)
SELECT
    ir.employee_name,
    ir.location_id,
    ir.statements
FROM
    Incorrect_records AS ir
WHERE
    ir.employee_name IN (SELECT sl.employee_name FROM suspect_list AS sl)
    AND ir.statements LIKE '%cash%';

-- Final check: does anyone outside the suspect list have statements about
-- cash? Same query with NOT IN. Returns no rows, so only the four
-- suspects have these allegations.
WITH error_count AS (
    SELECT
        ir.employee_name,
        COUNT(ir.employee_name) AS number_of_mistakes
    FROM
        Incorrect_records AS ir
    GROUP BY ir.employee_name
),
suspect_list AS (
    SELECT
        ec.employee_name,
        ec.number_of_mistakes
    FROM
        error_count AS ec
    WHERE
        ec.number_of_mistakes > (SELECT AVG(ec2.number_of_mistakes) FROM error_count AS ec2)
)
SELECT
    ir.employee_name,
    ir.location_id,
    ir.statements
FROM
    Incorrect_records AS ir
WHERE
    ir.employee_name NOT IN (SELECT sl.employee_name FROM suspect_list AS sl)
    AND ir.statements LIKE '%cash%';


/* Key findings:
- The data is largely reliable: the auditor and the surveyors agreed on
  1,518 of 1,620 sites (94%). 102 records have a different score.
- The wrong scores do not affect the earlier analysis. The source types
  match between the survey and the audit, so the Part 2 results hold.
- The errors are not spread evenly. 17 employees made at least one
  mistake, but four of them made more than the average.
- Those same four employees are the only ones with statements about cash
  payments in the auditor's notes.
- This is a reason to flag the four for review, not proof of wrongdoing.
  The right next step is to hand the findings to the people responsible
  for investigating, not to draw conclusions from the data alone.
*/