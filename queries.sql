-- ============================================================
--  Miami Real Estate: Where Are Miami's Most Expensive Neighborhoods?
--  The full SQL story: load -> explore -> decide -> clean -> analyze.
--  Engine: SQLite 3.
--
--  Source: Miami-Dade County Open Data Hub, "Property Point View"
--  (942,904 property records), loaded into a table called `properties`.
--  Raw column names come from the CSV header (some have spaces), so they are
--  quoted with "double quotes".
--
--  How to run it yourself:
--    1. Download the raw CSV from the Open Data Hub (see README).
--    2. sqlite3 miami.db
--    3. .mode csv
--       .import miami_properties_raw.csv properties
--    4. .read queries.sql
-- ============================================================


-- ============================================================
-- 1. FIRST LOOK
-- ============================================================
-- How many rows did we load?
SELECT COUNT(*) FROM properties;                       -- 942,904

-- I planned to study assessed (tax) value, but it came back empty in the
-- public export. This returns 0, which is why I pivoted to real SALE PRICE.
SELECT COUNT(*) AS rows_with_assessed_value
FROM properties
WHERE "Assessed Value" != '';                          -- 0

-- A huge chunk of sales are symbolic: $0 and $100 appear hundreds of
-- thousands of times (transfers, not market sales).
SELECT "Sale Amount", COUNT(*) AS n
FROM properties
GROUP BY "Sale Amount"
ORDER BY n DESC
LIMIT 10;

-- Price bands make the cutoff obvious: a "dead zone" with almost nothing
-- between $101 and $1,000, then real sales above. I cut at $10,000 to be safe.
SELECT
    CASE
        WHEN CAST("Sale Amount" AS INTEGER) = 0      THEN '1) $0'
        WHEN CAST("Sale Amount" AS INTEGER) <= 100   THEN '2) $1 - 100'
        WHEN CAST("Sale Amount" AS INTEGER) <= 1000  THEN '3) $101 - 1,000'
        WHEN CAST("Sale Amount" AS INTEGER) <= 10000 THEN '4) $1,001 - 10,000'
        ELSE                                              '5) over $10,000'
    END AS price_band,
    COUNT(*) AS sales
FROM properties
GROUP BY price_band
ORDER BY price_band;


-- ============================================================
-- 2. DECIDE: ZIP code, not "city"
-- ============================================================
-- My first instinct was to group by city. But more than half the sales fall
-- into two vague buckets ("MIAMI" and "UNINCORPORATED COUNTY"), useless for a
-- map. So I used ZIP code as the location instead.
SELECT "City", COUNT(*) AS sales
FROM properties
GROUP BY "City"
ORDER BY sales DESC
LIMIT 10;


-- ============================================================
-- 3. CLEAN: build the analysis table (-> 195,210 rows)
-- ============================================================
-- Keep only real residential sales: residential type, recent (2020+), priced
-- above $10,000. The property type lives in "DOR Classification Description".
-- The 7 NOT LIKE rules took a few passes -- I kept finding non-homes (vacant
-- land, docks, parking, commercial condos) slipping through, so I tightened
-- the filter until only real housing was left. Columns are renamed and CAST to
-- numbers; ZIP is trimmed to 5 digits (the raw field had a "-0000" suffix).
DROP TABLE IF EXISTS clean_sales;
CREATE TABLE clean_sales AS
SELECT
    "Address"                                      AS address,
    "City"                                         AS city,
    substr("Zip Code", 1, 5)                       AS zip_code,
    "DOR Classification Description"               AS property_type,
    CAST("Bedroom Count"    AS INTEGER)            AS bedrooms,
    CAST("Bath Count"       AS INTEGER)            AS bathrooms,
    CAST("Living Area Sq Ft" AS INTEGER)           AS living_area_sqft,
    CAST("Lot Size"         AS INTEGER)            AS lot_size_sqft,
    CAST("Year Built"       AS INTEGER)            AS year_built,
    CAST("Sale Amount"      AS INTEGER)            AS sale_amount,
    CAST(substr("Date of Sale", 1, 4) AS INTEGER) AS sale_year
FROM properties
WHERE "DOR Classification Description" LIKE '%RESIDENTIAL%'
  AND "DOR Classification Description" NOT LIKE '%VACANT%'
  AND "DOR Classification Description" NOT LIKE '%MIXED USE%'
  AND "DOR Classification Description" NOT LIKE '%COMMERCIAL%'
  AND "DOR Classification Description" NOT LIKE '%DOCK%'
  AND "DOR Classification Description" NOT LIKE '%PARKING%'
  AND "DOR Classification Description" NOT LIKE '%CAMPSITE%'
  AND CAST("Sale Amount" AS INTEGER) > 10000
  AND CAST(substr("Date of Sale", 1, 4) AS INTEGER) >= 2020;

-- From 942,904 raw rows down to the clean set.
SELECT COUNT(*) FROM clean_sales;                      -- 195,210


-- ============================================================
-- 4. PRICE OVERVIEW: why the median, not the average
-- ============================================================
-- The max sale is $345M and the average ($1.24M) is ~2.8x the median, so a
-- few giant sales drag the mean up. The median is the honest "typical home".
SELECT
    COUNT(*)         AS sales,        -- 195,210
    MIN(sale_amount) AS min_price,    -- 10,100
    MAX(sale_amount) AS max_price,    -- 345,000,000
    ROUND(AVG(sale_amount)) AS avg_price   -- 1,240,130
FROM clean_sales;

-- Median. SQLite has no MEDIAN function, so I rank the rows and AVERAGE the
-- one or two middle values. The rn IN ((cnt+1)/2, (cnt+2)/2) trick returns one
-- row for odd counts and the two middle rows for even counts -- matching how
-- Tableau computes the median.
SELECT ROUND(AVG(sale_amount)) AS median_price          -- 445,000
FROM (
    SELECT sale_amount,
        ROW_NUMBER() OVER (ORDER BY sale_amount) AS rn,
        COUNT(*)     OVER ()                     AS cnt
    FROM clean_sales
)
WHERE rn IN ((cnt + 1) / 2, (cnt + 2) / 2);


-- ============================================================
-- 5. Q1: median price by ZIP  (the map + the Top 10 bars)
-- ============================================================
-- Median price per ZIP (same odd/even median trick, per ZIP), keeping only
-- ZIPs with at least 100 sales so the median is reliable.
SELECT zip_code, ROUND(AVG(sale_amount)) AS median_price, cnt AS sales
FROM (
    SELECT zip_code, sale_amount,
        ROW_NUMBER() OVER (PARTITION BY zip_code ORDER BY sale_amount) AS rn,
        COUNT(*)     OVER (PARTITION BY zip_code) AS cnt
    FROM clean_sales
)
WHERE rn IN ((cnt + 1) / 2, (cnt + 2) / 2)
  AND cnt >= 100
GROUP BY zip_code
ORDER BY median_price DESC;
-- Top: 33109 Fisher Island $5,275,000. Cheapest reliable: 33126 $246,000
-- (~21x gap). Pricey = south coast + prestige inland; cheap = inland west/north.


-- ============================================================
-- 6. Q2: two kinds of expensive  (size vs. price per square foot)
-- ============================================================

-- Does price rise with size? Count by size bucket -- it does, and the jump
-- accelerates above 3,000 sqft.
SELECT
    CASE
        WHEN living_area_sqft < 1000 THEN '1) under 1,000 sqft'
        WHEN living_area_sqft < 2000 THEN '2) 1,000 - 2,000'
        WHEN living_area_sqft < 3000 THEN '3) 2,000 - 3,000'
        WHEN living_area_sqft < 4000 THEN '4) 3,000 - 4,000'
        ELSE                              '5) 4,000+'
    END AS size_bucket,
    COUNT(*) AS sales
FROM clean_sales
WHERE living_area_sqft > 0
GROUP BY size_bucket
ORDER BY size_bucket;

-- But "big = expensive" gets tangled with location. Median price per sqft by
-- ZIP separates them: high $/sqft = a premium for LOCATION (small urban
-- condos); high total but moderate $/sqft = a premium for SPACE (big homes).
SELECT zip_code, ROUND(AVG(price_per_sqft), 0) AS median_price_per_sqft, cnt AS sales
FROM (
    SELECT zip_code,
        sale_amount * 1.0 / living_area_sqft AS price_per_sqft,
        ROW_NUMBER() OVER (PARTITION BY zip_code
                           ORDER BY sale_amount * 1.0 / living_area_sqft) AS rn,
        COUNT(*)     OVER (PARTITION BY zip_code) AS cnt
    FROM clean_sales
    WHERE living_area_sqft > 0
)
WHERE rn IN ((cnt + 1) / 2, (cnt + 2) / 2)
  AND cnt >= 100
GROUP BY zip_code
ORDER BY median_price_per_sqft DESC;
-- Fisher Island tops both. Downtown/Brickell condos: high $/sqft, lower total.
-- Pinecrest: high total, lower $/sqft (paying for space).

-- Sanity check on the confounding: where do the big (4,000+ sqft) homes live?
-- They cluster in expensive and mid ZIPs, almost never in the cheapest ones --
-- so size and location overlap, but aren't the same thing.
SELECT zip_code, COUNT(*) AS big_homes
FROM clean_sales
WHERE living_area_sqft >= 4000
GROUP BY zip_code
ORDER BY big_homes DESC
LIMIT 15;
