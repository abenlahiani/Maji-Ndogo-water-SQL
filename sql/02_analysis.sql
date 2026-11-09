-- ============================================================
-- Maji Ndogo water services | Part 2: Clustering data for insights
-- Database: md_water_services (MySQL)
--
-- Goal: move from single records to patterns. Clean the employee
-- data, understand where sources are and who uses them, rank what
-- to repair first, and find when people queue the longest.
--
-- Steps:
--   1. Data hygiene: the employee table
--   2. Honouring the workforce
--   3. Analyzing geography and scale
--   4. Interpreting water source data
--   5. Prioritization with window functions
--   6. The human cost: queue analysis
-- ============================================================

USE md_water_services;

-- Safe update mode is switched off so the UPDATEs below can run
SET SQL_SAFE_UPDATES = 0;


-- ------------------------------------------------------------
-- Step 1: Data hygiene, preparing the employee table
-- ------------------------------------------------------------

-- Generate email addresses in the format first.last@ndogowater.gov:
-- replace the space with a dot, lowercase it, add the domain.
-- Preview with SELECT first, then UPDATE once the format is right.
SELECT
    CONCAT(LOWER(REPLACE(employee_name, ' ', '.')), '@ndogowater.gov') AS new_email
FROM
    employee;

UPDATE employee
SET email = CONCAT(LOWER(REPLACE(employee_name, ' ', '.')), '@ndogowater.gov');

-- Fix phone number formatting: phone numbers carried a trailing space,
-- which would make automated SMS fail. TRIM removes it.
SELECT LENGTH(TRIM(phone_number)) FROM employee;

UPDATE employee
SET phone_number = TRIM(phone_number);
-- Result: reliable contact details and consistent data
-- ------------------------------------------------------------
-- Step 2: Honouring the workforce
-- ------------------------------------------------------------

-- The three field surveyors with the most recorded visits
SELECT
    assigned_employee_id,
    COUNT(location_id) AS number_of_visits
FROM
    visits
GROUP BY assigned_employee_id
ORDER BY number_of_visits DESC
LIMIT 3;


-- ------------------------------------------------------------
-- Step 3: Analyzing geography and scale
-- ------------------------------------------------------------

-- Number of records per town, grouped within each province
SELECT
    province_name,
    town_name,
    COUNT(location_id) AS records_per_town
FROM
    location
GROUP BY province_name, town_name
ORDER BY province_name, records_per_town DESC;

-- Finding: every province and town is well covered, so the survey
-- represents the whole country. About 60% of water sources are rural,
-- which means repair teams will face long distances, poor roads and
-- limited supplies and labour.


-- ------------------------------------------------------------
-- Step 4: Interpreting water source data
-- ------------------------------------------------------------

-- Average number of people served by one source of each type
SELECT
    type_of_water_source,
    ROUND(AVG(number_of_people_served), 0) AS avg_people_per_source
FROM
    water_source
GROUP BY type_of_water_source;

-- Reading the result: a home tap shows 644 people. That is not 644 people
-- sharing one tap. Surveyors combined many households into one record
-- (about 6 people per home), so one record stands for roughly 100 taps.

-- Total population served per source type, and its share of the total
SELECT
    type_of_water_source,
    SUM(number_of_people_served) AS population_served,
    ROUND((SUM(number_of_people_served) / 27603984) * 100, 0) AS percentage_served
FROM
    water_source
GROUP BY type_of_water_source
ORDER BY population_served DESC;

-- Finding: shared taps serve 43% of the population, with about 2,000
-- people sharing each one on average. They are the clearest priority.


-- ------------------------------------------------------------
-- Step 5: Prioritization using window functions
-- ------------------------------------------------------------

-- Rank the sources within each type by the number of people they serve,
-- so repair teams start with the sources that help the most people.
-- tap_in_home is excluded: it is already the best source available.
SELECT
    source_id,
    type_of_water_source,
    number_of_people_served,
    RANK() OVER (
        PARTITION BY type_of_water_source
        ORDER BY number_of_people_served DESC
    ) AS priority_rank
FROM
    water_source
WHERE
    type_of_water_source != 'tap_in_home';

-- Note: sources serving the same number of people share a rank with RANK().
-- ROW_NUMBER() would give every source a unique position, which is easier
-- for a repair crew that needs a single order to follow.


-- ------------------------------------------------------------
-- Step 6: The human cost, queue analysis
-- ------------------------------------------------------------

-- Average queue time by day of the week.
-- NULLIF turns 0 into NULL so sources with no queue (home taps)
-- do not pull the average down.
SELECT
    DAYNAME(time_of_record) AS day_of_week,
    ROUND(AVG(NULLIF(time_in_queue, 0)), 0) AS avg_queue_time
FROM
    visits
GROUP BY day_of_week
ORDER BY avg_queue_time DESC;

-- Pivot table in SQL: average queue time for each hour of each day.
-- One CASE expression per day turns the days into columns.
SELECT
    TIME_FORMAT(TIME(time_of_record), '%H:00') AS hour_of_day,
    ROUND(AVG(CASE WHEN DAYNAME(time_of_record) = 'Sunday' THEN time_in_queue END), 0) AS Sunday,
    ROUND(AVG(CASE WHEN DAYNAME(time_of_record) = 'Monday' THEN time_in_queue END), 0) AS Monday,
    ROUND(AVG(CASE WHEN DAYNAME(time_of_record) = 'Tuesday' THEN time_in_queue END), 0) AS Tuesday,
    ROUND(AVG(CASE WHEN DAYNAME(time_of_record) = 'Wednesday' THEN time_in_queue END), 0) AS Wednesday,
    ROUND(AVG(CASE WHEN DAYNAME(time_of_record) = 'Thursday' THEN time_in_queue END), 0) AS Thursday,
    ROUND(AVG(CASE WHEN DAYNAME(time_of_record) = 'Friday' THEN time_in_queue END), 0) AS Friday,
    ROUND(AVG(CASE WHEN DAYNAME(time_of_record) = 'Saturday' THEN time_in_queue END), 0) AS Saturday
FROM
    visits
WHERE
    time_in_queue != 0 -- excludes sources with no queue
GROUP BY hour_of_day
ORDER BY hour_of_day;

/* Key findings from the queue analysis:
- Saturday is the worst day by far: average queues are about twice as long
  as on weekdays (246 minutes against 97 to 137). People seem to
  spend Saturday collecting water for the whole week.
- Monday has the longest weekday queues, in the morning and in the evening,
  as people collect water before and after the working day.
- Wednesday is the shortest weekday (97 minutes), though it still has an
  evening peak.
- Sunday has the shortest queues overall (82 minutes), most likely because
  families spend the day together and collect water on other days.
- On every day, mornings and evenings are the busiest hours.
*/

/* Overall insights and what they mean for the plan:
- The survey is representative: every province and town is covered, and
  about 60% of sources are rural, so repairs must plan for rural logistics.
- Shared taps are the biggest problem: 43% of people depend on them, with
  about 2,000 people per tap and the longest queues.
- 31% of people have a tap installed at home, but 45% of those homes
  (14% of the population) have a broken one, because the infrastructure
  behind the tap is not working. Fixing one plant or pipe can restore
  water to many homes at once.
- Wells serve 18% of the population and are the second priority.

Recommended actions:
- Immediate relief: send water tankers to the busiest shared taps at peak
  times, especially on Saturdays and Monday mornings.
- Short term: install extra shared taps where queues are long, and fit
  filters on contaminated wells (UV for biological contamination, reverse
  osmosis for chemical).
- Infrastructure: repair the systems behind broken home taps.
- Long term: bring queue times below 30 minutes, the UN guideline.
*/

-- Turn safe update mode back on
SET SQL_SAFE_UPDATES = 1;