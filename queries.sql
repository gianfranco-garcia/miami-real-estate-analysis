-- ============================================================
--  Miami Real Estate: Where Are Miami's Most Expensive Neighborhoods?
--  The full SQL story: load -> explore -> decide -> clean -> analyze.
--  Engine: SQLite 3.
--
--  Source: Miami-Dade County Open Data Hub, "Property Point View"
--  (~943K property records), loaded into a table called `properties`.
--  Raw column names come from the CSV header, so some have spaces and are
--  quoted with "double quotes". Adjust them if your header differs slightly.
-- ============================================================


-- ============================================================
-- 1. LOAD  (run these in the sqlite3 shell, not as SQL)
-- ============================================================
--   sqlite3 miami.db
--   .mode csv
--   .import miami_properties_raw.csv properties

-- How many rows did we load?
SELECT COUNT(*) FROM properties;          -- 942,904


-- ============================================================
-- 2. EXPLORE: what is actually usable in here?
-- ============================================================

-- I planned to study assessed (tax) value... but it came back empty in the
-- public export. This returns 0, which is why I pivoted to real SALE PRICE.
SELECT COUNT(*) AS rows_with_assessed_value
FROM properties
WHERE "Assessed Value" != '';

-- Looking at sale prices, a huge chunk are symbolic: $0 and $100 show up
-- hundreds of thousands of times (these are transfers, not market sales).
SELECT "Sale Amount", COUNT(*) AS n
FROM properties
GROUP BY "Sale Amount"
ORDER BY n DESC
LIMIT 10;

-- Price bands make the cutoff decision obvious. There's a "dead zone":
-- tons of $0/$100 sales, almost nothing between $101 and $1,000, then real
-- market sales above. I drew the line at $10,000 to be safe.
SELECT
    CASE
        WHEN CAST("Sale Amount" AS INTEGER) = 0     THEN '1) $0'
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
-- 3. DECIDE: ZIP code, not "city"
-- ============================================================
-- My first instinct was to group by city. But more than half the sales fall
-- into two vague buckets ("Miami" and "Unincorporated County"), which is
-- useless for a map. So I used ZIP code as the location instead.
SELECT "City", COUNT(*) AS sales
FROM properties
GROUP BY "City"
ORDER BY sales DESC
LIMIT 10;


-- ============================================================
-- 4. CLEAN: build the analysis table
-- ============================================================
-- Keep only real residential sales: residential type, recent (2020+), priced
-- above $10,000. Rename columns to clean names, CAST the numbers, and trim ZIP
-- to 5 digits (the raw field had a "-0000" suffix). The 7 NOT LIKE rules took
-- a few passes -- I kept finding non-homes (docks, parking) that slipped
-- through, so I tightened the filter until only real housing was left.
DROP TABLE IF EXISTS clean_sales;
CREATE TABLE clean_sales AS
SELECT
    "Address"                                     AS address,
    "City"                                        AS city,
    substr("Zip Code", 1, 5)                      AS zip_code,
    "Property Type"                               AS property_type,
    CAST("Bedrooms"      AS INTEGER)              AS bedrooms,
    CAST("Bathrooms"     AS REAL)                 AS bathrooms,
    CAST("Living Area"   AS INTEGER)              AS living_area_sqft,
    CAST("Lot Size"      AS INTEGER)              AS lot_size_sqft,
    CAST("Year Built"    AS INTEGER)              AS year_built,
    CAST("Sale Amount"   AS INTEGER)              AS sale_amount,
    CAST(substr("Date of Sale", 1, 4) AS INTEGER) AS sale_year
FROM properties
WHERE "Property Type" LIKE '%RESIDENTIAL%'
  AND "Property Type" NOT LIKE '%VACANT%'
  AND "Property Type" NOT LIKE '%MIXED USE%'
  AND "Property Type" NOT LIKE '%COMMERCIAL%'
  AND "Property Type" NOT LIKE '%DOCK%'
  AND "Property Type" NOT LIKE '%PARKING%'
  AND "Property Type" NOT LIKE '%CAMPSITE%'
  AND CAST("Sale Amount" AS INTEGER) > 10000
  AND CAST(substr("Date of Sale", 1, 4) AS INTEGER) >= 2020;

-- From ~943K raw rows down to the clean set.
SELECT COUNT(*) FROM clean_sales;         -- 195,210


-- ============================================================
-- 5. PRICE OVERVIEW: why the median, not the average
-- ============================================================
-- The max sale is ~$345M and the average is ~3x the median, so a few giant
-- sales drag the mean way up. The median is the honest "typical home" number.
SELECT
    COUNT(*)         AS sales,
    MIN(sale_amount) AS min_price,
    MAX(sale_amount) AS max_price,
    AVG(sale_amount) AS avg_price
FROM clean_sales;

-- Median (SQLite has no MEDIAN function, so order the rows and grab the middle).
SELECT sale_amount AS median_price
FROM clean_sales
ORDER BY sale_amount
LIMIT 1
OFFSET (SELECT COUNT(*) FROM clean_sales) / 2;   -- ~445,000


-- ============================================================
-- 6. Q1: median price by ZIP  (the map + the Top 10 bars)
-- ============================================================
-- Median price per ZIP using window functions, keeping only ZIPs with at
-- least 100 sales so the median is reliable.
SELECT zip_code, median_price, sales
FROM (
    SELECT
        zip_code,
        sale_amount AS median_price,
        ROW_NUMBER() OVER (PARTITION BY zip_code ORDER BY sale_amount) AS rn,
        COUNT(*)     OVER (PARTITION BY zip_code) AS sales
    FROM clean_sales
)
WHERE rn = (sales + 1) / 2
  AND sales >= 100
ORDER BY median_price DESC;
-- Top: 33109 Fisher Island $5.28M. Cheapest reliable: 33126 $246K (~21x gap).


-- ============================================================
-- 7. Q2: two kinds of expensive  (size vs. price per square foot)
-- ============================================================

-- First, does price rise with size? Median price per size bucket. It does,
-- and it accelerates above 3,000 sqft.
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

-- But "big homes cost more" gets tangled with location. Price per sqft by ZIP
-- separates the two: high $/sqft = a premium for LOCATION (small urban condos);
-- high total but moderate $/sqft = a premium for SPACE (big suburban homes).
-- The *1.0 forces decimal division.
SELECT zip_code, median_price_per_sqft, sales
FROM (
    SELECT
        zip_code,
        sale_amount * 1.0 / living_area_sqft AS median_price_per_sqft,
        ROW_NUMBER() OVER (PARTITION BY zip_code
                           ORDER BY sale_amount * 1.0 / living_area_sqft) AS rn,
        COUNT(*)     OVER (PARTITION BY zip_code) AS sales
    FROM clean_sales
    WHERE living_area_sqft > 0
)
WHERE rn = (sales + 1) / 2
  AND sales >= 100
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


-- ============================================================
-- 8. Q3: does the age of the house matter?
-- ============================================================
-- Median price by build era. Comes out as a U-shape (older and newer cost
-- more, the middle is cheapest)...
SELECT era, median_price, sales
FROM (
    SELECT
        era,
        sale_amount AS median_price,
        ROW_NUMBER() OVER (PARTITION BY era ORDER BY sale_amount) AS rn,
        COUNT(*)     OVER (PARTITION BY era) AS sales
    FROM (
        SELECT
            sale_amount,
            CASE
                WHEN year_built < 1950 THEN '1) before 1950'
                WHEN year_built < 1970 THEN '2) 1950 - 1969'
                WHEN year_built < 1990 THEN '3) 1970 - 1989'
                WHEN year_built < 2010 THEN '4) 1990 - 2009'
                ELSE                        '5) 2010+'
            END AS era
        FROM clean_sales
        WHERE year_built > 0
    )
)
WHERE rn = (sales + 1) / 2
ORDER BY era;

-- ...but age is mostly a proxy. Breaking each era down by size and $/sqft shows
-- old homes are small but pricey per foot (location), new homes are bigger.
SELECT
    era,
    COUNT(*)                                  AS sales,
    AVG(living_area_sqft)                     AS avg_sqft,
    AVG(sale_amount * 1.0 / living_area_sqft) AS avg_price_per_sqft
FROM (
    SELECT
        sale_amount, living_area_sqft,
        CASE
            WHEN year_built < 1950 THEN '1) before 1950'
            WHEN year_built < 1970 THEN '2) 1950 - 1969'
            WHEN year_built < 1990 THEN '3) 1970 - 1989'
            WHEN year_built < 2010 THEN '4) 1990 - 2009'
            ELSE                        '5) 2010+'
        END AS era
    FROM clean_sales
    WHERE year_built > 0 AND living_area_sqft > 0
)
GROUP BY era
ORDER BY era;
