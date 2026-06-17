-- ============================================================
--  Miami Real Estate: Where Are Miami's Most Expensive Neighborhoods?
--  SQL used to load, clean, and analyze Miami-Dade home sales (2020-2024).
--  Engine: SQLite 3.
--
--  Source: Miami-Dade County Open Data Hub, "Property Point View"
--  (~943K property records), loaded into a table called `properties`.
--  The raw column names come straight from the CSV header, so a few have
--  spaces and are quoted with "double quotes". If your header differs
--  slightly, adjust those names to match.
-- ============================================================


-- ============================================================
-- 1. LOAD  (run these in the sqlite3 shell, not as SQL)
-- ============================================================
--   sqlite3 miami.db
--   .mode csv
--   .import miami_properties_raw.csv properties


-- ============================================================
-- 2. FIRST LOOK
-- ============================================================
-- How many rows did we load?
SELECT COUNT(*) FROM properties;

-- The assessed value column came back empty, which is why I pivoted to
-- sale price (this returns 0).
SELECT COUNT(*) AS rows_with_assessed_value
FROM properties
WHERE "Assessed Value" != '';

-- Many sales are symbolic ($0 or $100) — transfers, not real market prices.
SELECT "Sale Amount", COUNT(*) AS n
FROM properties
GROUP BY "Sale Amount"
ORDER BY n DESC
LIMIT 10;


-- ============================================================
-- 3. BUILD THE CLEAN TABLE
-- ============================================================
-- Keep only real residential sales: residential type, recent (2020+),
-- priced above $10,000. Rename columns to clean names, CAST the numbers,
-- and trim ZIP to 5 digits (the raw field had a "-0000" suffix).
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

-- Final row count (should be ~195,210).
SELECT COUNT(*) FROM clean_sales;


-- ============================================================
-- 4. PRICE OVERVIEW  (average vs median)
-- ============================================================
-- The average gets pulled way up by a few enormous sales, so the median
-- is the honest "typical home" number.
SELECT
    COUNT(*)         AS sales,
    MIN(sale_amount) AS min_price,
    MAX(sale_amount) AS max_price,
    AVG(sale_amount) AS avg_price
FROM clean_sales;

-- Median (SQLite has no MEDIAN function, so order and grab the middle row).
SELECT sale_amount AS median_price
FROM clean_sales
ORDER BY sale_amount
LIMIT 1
OFFSET (SELECT COUNT(*) FROM clean_sales) / 2;


-- ============================================================
-- 5. WHY ZIP CODE, NOT CITY
-- ============================================================
-- More than half the sales fall into vague "city" labels like "Miami" and
-- "Unincorporated County", so city is useless as a location. ZIP is precise.
SELECT city, COUNT(DISTINCT zip_code) AS zips, COUNT(*) AS sales
FROM clean_sales
GROUP BY city
ORDER BY sales DESC
LIMIT 10;


-- ============================================================
-- 6. Q1 - MEDIAN PRICE BY ZIP  (the map + the Top 10 bars)
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


-- ============================================================
-- 7. Q2 - TWO KINDS OF EXPENSIVE  (price per square foot by ZIP)
-- ============================================================
-- Median price by size bucket: price rises with size and speeds up at the top.
SELECT
    size_bucket,
    COUNT(*) AS sales
FROM (
    SELECT
        CASE
            WHEN living_area_sqft < 1000 THEN '1) under 1,000 sqft'
            WHEN living_area_sqft < 2000 THEN '2) 1,000-2,000'
            WHEN living_area_sqft < 3000 THEN '3) 2,000-3,000'
            WHEN living_area_sqft < 4000 THEN '4) 3,000-4,000'
            ELSE                              '5) 4,000+'
        END AS size_bucket
    FROM clean_sales
    WHERE living_area_sqft > 0
)
GROUP BY size_bucket
ORDER BY size_bucket;

-- Price per sqft separates "expensive because of location" (high $/sqft, small
-- condos) from "expensive because of size" (big homes, lower $/sqft). The *1.0
-- forces decimal division. Only homes with a real living area.
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


-- ============================================================
-- 8. Q3 - DOES AGE MATTER?  (median price by decade built)
-- ============================================================
-- Bucket homes by build era, then median price per bucket. Comes out as a
-- U-shape, but age mostly stands in for location and size.
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
                WHEN year_built < 1970 THEN '2) 1950-1969'
                WHEN year_built < 1990 THEN '3) 1970-1989'
                WHEN year_built < 2010 THEN '4) 1990-2009'
                ELSE                        '5) 2010+'
            END AS era
        FROM clean_sales
        WHERE year_built > 0
    )
)
WHERE rn = (sales + 1) / 2
ORDER BY era;
