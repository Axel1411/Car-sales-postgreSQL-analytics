-- ====================================================================
-- PROJECT : Car Sales Analytics - SQL Portfolio (PostgreSQL)
-- AUTHOR  : <your name>  |  GitHub: <link>  |  LinkedIn: <link>
--
-- BUSINESS CONTEXT
--   A multi-dealership car retailer in Indonesia (12 dealerships, 10 brands,
--   Jan 2023 - Oct 2026). Leadership, sales, marketing, operations, finance
--   and service teams each need answers from the same database. Every
--   section below is one business task, written as the question a manager
--   would ask.
--
-- DATA MODEL (9 tables, synthetic data)
--   dealerships, employees, customers, brands, car_models, vehicles,
--   sales, financing, service_records
--
-- SQL SKILLS DEMONSTRATED
--   Joins (inner, left, self), aggregation, FILTER, CASE, CTEs, window
--   functions (RANK, LAG, NTILE, running totals), views, date logic,
--   percentiles, calendar spines (generate_series), data-quality checks,
--   indexing and EXPLAIN ANALYZE.
--
-- HOW TO RUN
--   1. Create an empty database and run sql/01_schema_and_data.sql
--   2. Run SECTION 0 below once (creates 3 helper views)
--   3. Run any query. Each one starts with the business question.
--
-- DEFINITIONS (say these out loud in an interview)
--   revenue      = SUM(sale_price). sale_price is ALREADY after discount.
--   gross profit = sale_price - cost_price (ignores salaries, service
--                  costs and financing costs).
--   data cut-off = latest date in the data (v_params.as_of_date).
--                  2026 is a PARTIAL year (Jan-Oct): compare like-for-like.
--   purchase occasion = one customer on one day. A company buying 3 cars
--                  on the same day is ONE occasion (see v_purchase_events).
-- ====================================================================


-- ====================================================================
-- SECTION 0: SETUP (run once)
-- ====================================================================

-- 0.1 Parameters derived from the data: no hardcoded dates in the questions.
CREATE OR REPLACE VIEW v_params AS
SELECT GREATEST((SELECT MAX(sale_date) FROM sales),
                (SELECT MAX(arrival_date) FROM vehicles))      AS as_of_date,
       EXTRACT(YEAR FROM (SELECT MAX(sale_date) FROM sales))::int      AS current_year,
       EXTRACT(YEAR FROM (SELECT MAX(sale_date) FROM sales))::int - 1  AS last_full_year;

-- 0.2 One row per sale with every dimension attached. Build everything on this.
CREATE OR REPLACE VIEW v_sales_detail AS
SELECT s.sale_id, s.sale_date,
       EXTRACT(YEAR FROM s.sale_date)::int       AS sale_year,
       DATE_TRUNC('month', s.sale_date)::date    AS sale_month,
       s.customer_id, s.employee_id, s.vehicle_id,
       v.dealership_id, m.model_id, b.brand_id,
       s.sale_price, s.discount_amount, v.list_price, v.cost_price,
       s.sale_price - v.cost_price               AS gross_profit,
       ROUND(100.0 * s.discount_amount / v.list_price, 2) AS discount_pct,
       s.sale_date - v.arrival_date              AS days_to_sell,
       s.payment_method, s.sales_channel,
       v.vin, v.model_year, v.color,
       m.model_name, m.segment, m.fuel_type,
       b.brand_name, b.country_of_origin,
       d.dealership_name, d.city AS dealership_city, d.province,
       e.full_name AS salesperson,
       c.full_name AS customer, c.customer_type, c.city AS customer_city,
       EXTRACT(YEAR FROM AGE(s.sale_date, c.birth_date))::int AS customer_age
FROM sales s
JOIN vehicles v    ON v.vehicle_id    = s.vehicle_id
JOIN car_models m  ON m.model_id      = v.model_id
JOIN brands b      ON b.brand_id      = m.brand_id
JOIN dealerships d ON d.dealership_id = v.dealership_id
JOIN employees e   ON e.employee_id   = s.employee_id
JOIN customers c   ON c.customer_id   = s.customer_id;

-- 0.3 One row per customer per purchase day (fleet orders count once).
CREATE OR REPLACE VIEW v_purchase_events AS
SELECT customer_id, sale_date,
       COUNT(*)        AS cars,
       SUM(sale_price) AS revenue,
       ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY sale_date) AS purchase_no
FROM sales
GROUP BY customer_id, sale_date;


-- ====================================================================
-- CATEGORY 1: Sales analysis with SELECT, Aggregation, filtering, grouping
-- "We (the Leadership team) have been tasked with generating the
--  necessary data points for the sales side."
-- ====================================================================

-- 1.1  Headline numbers for the whole period.
SELECT COUNT(*)                                   AS cars_sold,
       SUM(sale_price)                            AS total_revenue,
       SUM(gross_profit)                          AS gross_profit,
       ROUND(100.0 * SUM(gross_profit) / SUM(sale_price), 1) AS margin_pct,
       ROUND(AVG(sale_price))                     AS avg_price,
       ROUND(AVG(gross_profit))                   AS avg_profit_per_car
FROM v_sales_detail;

-- 1.2 Total revenue and number of cars sold per year.
SELECT EXTRACT(YEAR FROM sale_date)::int AS year,
       COUNT(*) AS cars_sold,
       SUM(sale_price) AS revenue
FROM sales
GROUP BY 1
ORDER BY 1;

-- 1.3  Which brands lead each year? Top 3 per year by gross profit, with units, revenue and margin.
--      (Money shown in IDR billions so the numbers are readable.)
WITH brand_year AS (
  SELECT sale_year, brand_name,
         COUNT(*)          AS units,
         SUM(sale_price)   AS revenue,
         SUM(gross_profit) AS gross_profit
  FROM v_sales_detail
  GROUP BY sale_year, brand_name
),
ranked AS (
  SELECT brand_year.*,
         RANK() OVER (PARTITION BY sale_year ORDER BY gross_profit DESC) AS rank_in_year
  FROM brand_year
)
SELECT sale_year, rank_in_year, brand_name, units,
       ROUND(revenue / 1e9, 1)                  AS revenue_bn,
       ROUND(gross_profit / 1e9, 1)             AS gross_profit_bn,
       ROUND(100.0 * gross_profit / revenue, 1) AS margin_pct
FROM ranked
WHERE rank_in_year <= 3
ORDER BY sale_year, rank_in_year;

-- 1.3b Same data as a compact table: one row per brand, one column per year (revenue, IDR billions).
--      (Year columns are fixed on purpose. 2026 covers Jan-Oct only.)
SELECT brand_name,
       ROUND(SUM(sale_price) FILTER (WHERE sale_year = 2023) / 1e9, 1) AS "2023",
       ROUND(SUM(sale_price) FILTER (WHERE sale_year = 2024) / 1e9, 1) AS "2024",
       ROUND(SUM(sale_price) FILTER (WHERE sale_year = 2025) / 1e9, 1) AS "2025",
       ROUND(SUM(sale_price) FILTER (WHERE sale_year = 2026) / 1e9, 1) AS "2026_jan_oct",
       ROUND(SUM(sale_price) / 1e9, 1)                                 AS total_bn
FROM v_sales_detail
GROUP BY brand_name
ORDER BY total_bn DESC;


-- 1.4  Japan vs China vs South Korea.
SELECT country_of_origin,
       COUNT(*)          AS units,
       SUM(sale_price)   AS revenue,
       SUM(gross_profit) AS gross_profit,
       ROUND(100.0 * SUM(gross_profit) / SUM(sale_price), 1) AS margin_pct
FROM v_sales_detail
GROUP BY country_of_origin
ORDER BY revenue DESC;

-- 1.5 Revenue yoy and percentage
SELECT sd.sale_year,
       COUNT(*)           AS cars_sold,
       SUM(sd.sale_price) AS revenue,
       ROUND(100.0 * (SUM(sd.sale_price) - LAG(SUM(sd.sale_price)) OVER (ORDER BY sd.sale_year))
             / LAG(SUM(sd.sale_price)) OVER (ORDER BY sd.sale_year), 1) AS revenue_yoy_pct
FROM v_sales_detail sd
CROSS JOIN v_params p
WHERE (EXTRACT(MONTH FROM sd.sale_date), EXTRACT(DAY FROM sd.sale_date))
   <= (EXTRACT(MONTH FROM p.as_of_date), EXTRACT(DAY FROM p.as_of_date))
GROUP BY sd.sale_year
ORDER BY sd.sale_year desc;


-- 1.6  Seasonality: which calendar months are strong? (index 1.00 = an average month; full years only)
WITH m AS (
  SELECT sale_year, EXTRACT(MONTH FROM sale_date)::int AS mon, COUNT(*) AS units
  FROM v_sales_detail
  GROUP BY 1, 2
),
scaled AS (
  SELECT m.*, units / AVG(units) OVER (PARTITION BY sale_year) AS idx
  FROM m
  JOIN v_params p ON m.sale_year <= p.last_full_year
)
SELECT mon, ROUND(AVG(units), 1) AS avg_units, ROUND(AVG(idx), 2) AS seasonal_index
FROM scaled
GROUP BY mon
ORDER BY mon;

-- TRY NEXT (no solution): Is margin shrinking as discounts grow? What would next quarter's
-- revenue be if it repeats last year's seasonal index? Which segment drove the 2025 growth?


-- ====================================================================
-- CATEGORY 2: DEALERSHIP & REGIONAL PERFORMANCE
-- "Regional management wants to know which branches carry the company
--  and which are falling behind."
-- ====================================================================

-- 2.1  Top 5 dealerships in the latest FULL year with Aggregation, filtering, grouping and joins
SELECT sd.dealership_name, sd.dealership_city,
       COUNT(*)          AS units,
       SUM(sd.sale_price)   AS revenue,
       SUM(sd.gross_profit) AS gross_profit,
       ROUND(100.0 * SUM(sd.gross_profit) / SUM(sd.sale_price), 1) AS margin_pct
FROM v_sales_detail sd
JOIN v_params p ON sd.sale_year = p.last_full_year
GROUP BY sd.dealership_name, sd.dealership_city
ORDER BY revenue DESC
LIMIT 5;

-- 2.2  Profit and margin by province.
SELECT province,
       COUNT(*)          AS units,
       SUM(sale_price)   AS revenue,
       SUM(gross_profit) AS gross_profit,
       ROUND(100.0 * SUM(gross_profit) / SUM(sale_price), 1) AS margin_pct
FROM v_sales_detail
GROUP BY province
ORDER BY gross_profit DESC;

-- 2.3  Best-selling model at EACH dealership (RANK keeps ties visible; ROW_NUMBER would hide them).
WITH ranked AS (
  SELECT dealership_name, model_name, COUNT(*) AS units,
         RANK() OVER (PARTITION BY dealership_name ORDER BY COUNT(*) DESC) AS rnk
  FROM v_sales_detail
  GROUP BY dealership_name, model_name
)
SELECT dealership_name, model_name, units
FROM ranked
WHERE rnk = 1
ORDER BY units DESC;

-- 2.4  Contribution to company revenue, with a running total (how concentrated are we?).
SELECT dealership_name, revenue,
       ROUND(100.0 * revenue / SUM(revenue) OVER (), 1)                          AS pct_of_company,
       ROUND(100.0 * SUM(revenue) OVER (ORDER BY revenue DESC) / SUM(revenue) OVER (), 1) AS cumulative_pct
FROM (
  SELECT dealership_name, SUM(sale_price) AS revenue
  FROM v_sales_detail
  GROUP BY dealership_name
) t
ORDER BY revenue DESC;

-- 2.5  Who gives away the most margin? Discount as % of list price vs margin.
SELECT dealership_name,
       ROUND(100.0 * SUM(discount_amount) / SUM(list_price), 2) AS discount_pct_of_list,
       ROUND(100.0 * SUM(gross_profit) / SUM(sale_price), 1)    AS margin_pct,
       COUNT(*) FILTER (WHERE gross_profit < 0)                 AS loss_deals
FROM v_sales_detail
GROUP BY dealership_name
ORDER BY discount_pct_of_list DESC;

-- 2.6  Growth leaders: each dealership's revenue growth, latest full year vs the year before.
WITH y AS (
  SELECT dealership_name, sale_year, SUM(sale_price) AS revenue
  FROM v_sales_detail
  GROUP BY dealership_name, sale_year
),
g AS (
  SELECT y.*, LAG(revenue) OVER (PARTITION BY dealership_name ORDER BY sale_year) AS prev_revenue
  FROM y
)
SELECT g.dealership_name, g.sale_year, g.revenue, g.prev_revenue,
       ROUND(100.0 * (g.revenue - g.prev_revenue) / g.prev_revenue, 1) AS yoy_pct
FROM g
JOIN v_params p ON g.sale_year = p.last_full_year
ORDER BY yoy_pct DESC;

-- TRY NEXT: Do dealerships in the same city compete with each other? Which province
-- over-indexes on pickups? Which dealership has the lowest EV share, and does it match
-- its customers' age?


-- ====================================================================
-- CATEGORY 3: CUSTOMER ANALYSIS
-- "Marketing wants to know who our customers are, who comes back,
--  and who is worth the most."
-- Unit of analysis: purchase OCCASION (a fleet order = 1 occasion).
-- ====================================================================

-- 3.1  Returning buyers: how many customers came once, twice, 3+ times?
SELECT CASE WHEN n >= 3 THEN '3+' ELSE n::text END AS purchase_occasions,
       COUNT(*) AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM (SELECT customer_id, COUNT(*) AS n FROM v_purchase_events GROUP BY customer_id) t
GROUP BY 1
ORDER BY 1;

-- 3.2  Repeat rate by customer type.
SELECT c.customer_type,
       COUNT(*)                                           AS buyers,
       COUNT(*) FILTER (WHERE t.n > 1)                    AS repeat_buyers,
       ROUND(100.0 * COUNT(*) FILTER (WHERE t.n > 1) / COUNT(*), 1) AS repeat_rate_pct,
       ROUND(AVG(t.n), 2)                                 AS avg_occasions_per_buyer
FROM (SELECT customer_id, COUNT(*) AS n FROM v_purchase_events GROUP BY customer_id) t
JOIN customers c ON c.customer_id = t.customer_id
GROUP BY c.customer_type;

-- 3.3  Fair repeat rate: only customers whose first purchase was 2+ years before the cut-off,
--      and did they return WITHIN 2 years? (A 2026 buyer has had no time to return.)
WITH firsts  AS (SELECT customer_id, sale_date AS first_date  FROM v_purchase_events WHERE purchase_no = 1),
     seconds AS (SELECT customer_id, sale_date AS second_date FROM v_purchase_events WHERE purchase_no = 2)
SELECT COUNT(*) AS matured_customers,
       COUNT(*) FILTER (WHERE s.second_date <= f.first_date + INTERVAL '2 years') AS returned_within_2y,
       ROUND(100.0 * COUNT(*) FILTER (WHERE s.second_date <= f.first_date + INTERVAL '2 years') / COUNT(*), 1) AS return_rate_2y_pct
FROM firsts f
LEFT JOIN seconds s USING (customer_id)
CROSS JOIN v_params p
WHERE f.first_date <= p.as_of_date - INTERVAL '2 years';

-- 3.4  How long until a customer comes back? (days between 1st and 2nd purchase occasion)
SELECT COUNT(*)                                            AS returning_customers,
       MIN(days)                                           AS min_days,
       ROUND(AVG(days))                                    AS avg_days,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY days)::numeric) AS median_days,
       MAX(days)                                           AS max_days
FROM (
  SELECT b.sale_date - a.sale_date AS days
  FROM v_purchase_events a
  JOIN v_purchase_events b ON b.customer_id = a.customer_id AND a.purchase_no = 1 AND b.purchase_no = 2
) t;

-- 3.5  Brand loyalty: of customers who came back, what % bought the SAME brand again?
--      Compare loyalty_pct with each brand's market share to see real loyalty vs plain popularity.
WITH occ AS (
  SELECT customer_id, sale_date, MIN(sale_id) AS sale_id,
         ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY sale_date) AS n
  FROM sales
  GROUP BY customer_id, sale_date
),
with_brand AS (
  SELECT o.customer_id, o.n, d.brand_name
  FROM occ o
  JOIN v_sales_detail d ON d.sale_id = o.sale_id
)
SELECT a.brand_name AS first_brand,
       COUNT(*) AS returning_customers,
       COUNT(*) FILTER (WHERE a.brand_name = b.brand_name) AS bought_same_brand,
       ROUND(100.0 * COUNT(*) FILTER (WHERE a.brand_name = b.brand_name) / COUNT(*), 1) AS loyalty_pct
FROM with_brand a
JOIN with_brand b ON b.customer_id = a.customer_id AND a.n = 1 AND b.n = 2
GROUP BY a.brand_name
ORDER BY loyalty_pct DESC;

-- 3.6  Does servicing with us predict coming back to buy? (matured customers, 2-year window)
WITH occ AS (
  SELECT customer_id, sale_date, MIN(sale_id) AS sale_id,
         ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY sale_date) AS n
  FROM sales
  GROUP BY customer_id, sale_date
),
f AS (SELECT customer_id, sale_date AS first_date, sale_id FROM occ WHERE n = 1),
s AS (SELECT customer_id, sale_date AS second_date          FROM occ WHERE n = 2)
SELECT CASE WHEN EXISTS (SELECT 1 FROM service_records r WHERE r.sale_id = f.sale_id)
            THEN 'Serviced with us' ELSE 'Never serviced' END AS first_car,
       COUNT(*) AS customers,
       COUNT(*) FILTER (WHERE s.second_date <= f.first_date + INTERVAL '2 years') AS returned_within_2y,
       ROUND(100.0 * COUNT(*) FILTER (WHERE s.second_date <= f.first_date + INTERVAL '2 years') / COUNT(*), 1) AS return_rate_pct
FROM f
LEFT JOIN s USING (customer_id)
CROSS JOIN v_params p
WHERE f.first_date <= p.as_of_date - INTERVAL '2 years'
GROUP BY 1;
-- (Simplification: "serviced" counts any visit, including ones after the 2nd purchase.)

-- 3.7  RFM segmentation: Recency, Frequency, Monetary.
WITH cust AS (
  SELECT customer_id, MAX(sale_date) AS last_purchase, COUNT(*) AS frequency, SUM(revenue) AS monetary
  FROM v_purchase_events
  GROUP BY customer_id
),
scored AS (
  SELECT c.*, p.as_of_date - c.last_purchase AS recency_days,
         NTILE(4) OVER (ORDER BY c.last_purchase) AS r_score,   -- 4 = bought most recently
         LEAST(c.frequency, 4)                    AS f_score,   -- 4 = four or more occasions
         NTILE(4) OVER (ORDER BY c.monetary)      AS m_score    -- 4 = biggest spenders
  FROM cust c
  CROSS JOIN v_params p
)
SELECT CASE WHEN r_score >= 3 AND f_score >= 3 THEN 'Champions'
            WHEN f_score >= 3                    THEN 'Loyal'
            WHEN r_score = 1  AND f_score >= 2   THEN 'At risk (repeat buyer gone quiet)'
            WHEN f_score = 1  AND r_score >= 3   THEN 'New (recent first purchase)'
            ELSE 'One-time, long ago' END AS segment,
       COUNT(*)                 AS customers,
       ROUND(AVG(recency_days)) AS avg_days_since_purchase,
       ROUND(AVG(frequency), 1) AS avg_occasions,
       SUM(monetary)            AS revenue
FROM scored
GROUP BY 1
ORDER BY revenue DESC;

-- 3.8  Value tiers by PERCENTILE (no hardcoded rupiah thresholds).
WITH cust AS (
  SELECT customer_id, SUM(sale_price) AS total
  FROM sales
  GROUP BY customer_id
),
tiered AS (
  SELECT cust.*, PERCENT_RANK() OVER (ORDER BY total) AS pr
  FROM cust
)
SELECT CASE WHEN pr >= 0.9 THEN '1) Top 10%'
            WHEN pr >= 0.5 THEN '2) Middle 40%'
            ELSE '3) Bottom 50%' END AS tier,
       COUNT(*)   AS customers,
       SUM(total) AS revenue,
       ROUND(100.0 * SUM(total) / SUM(SUM(total)) OVER (), 1) AS revenue_share_pct,
       MIN(total) AS smallest_customer_spend
FROM tiered
GROUP BY 1
ORDER BY 1;

-- 3.9  Individual vs Corporate.
SELECT customer_type,
       COUNT(DISTINCT customer_id)                          AS customers,
       COUNT(*)                                             AS cars_bought,
       ROUND(1.0 * COUNT(*) / COUNT(DISTINCT customer_id), 2) AS cars_per_customer,
       SUM(sale_price)                                      AS revenue,
       ROUND(AVG(sale_price))                               AS avg_price
FROM v_sales_detail
GROUP BY customer_type;

-- 3.10 Who buys what? Segment mix by age group (individuals only, age at purchase).
SELECT CASE WHEN customer_age < 30 THEN '1) Under 30'
            WHEN customer_age < 45 THEN '2) 30-44'
            WHEN customer_age < 60 THEN '3) 45-59'
            ELSE '4) 60+' END AS age_group,
       COUNT(*) AS cars,
       ROUND(100.0 * COUNT(*) FILTER (WHERE segment = 'Hatchback') / COUNT(*), 1) AS hatchback_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE segment = 'EV')        / COUNT(*), 1) AS ev_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE segment = 'MPV')       / COUNT(*), 1) AS mpv_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE segment = 'SUV')       / COUNT(*), 1) AS suv_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE segment = 'Sedan')     / COUNT(*), 1) AS sedan_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE segment = 'Pickup')    / COUNT(*), 1) AS pickup_pct
FROM v_sales_detail
WHERE customer_type = 'Individual' AND customer_age IS NOT NULL
GROUP BY 1
ORDER BY 1;

-- 3.11 Pareto: what % of buying customers generate 50% of revenue?
WITH cust_rev AS (
  SELECT customer_id, SUM(sale_price) AS rev FROM sales GROUP BY customer_id
),
cum AS (
  SELECT rev,
         SUM(rev) OVER (ORDER BY rev DESC)     AS running,
         SUM(rev) OVER ()                      AS total,
         ROW_NUMBER() OVER (ORDER BY rev DESC) AS rn,
         COUNT(*) OVER ()                      AS n
  FROM cust_rev
)
SELECT ROUND(100.0 * MIN(rn) / MAX(n), 1) AS pct_of_customers_for_half_revenue
FROM cum
WHERE running >= 0.5 * total;

-- 3.12 Registered but never bought: by registration year.
SELECT EXTRACT(YEAR FROM c.registered_date)::int AS registered_year,
       COUNT(*) AS customers_without_purchase
FROM customers c
LEFT JOIN sales s ON s.customer_id = c.customer_id
WHERE s.sale_id IS NULL
GROUP BY 1
ORDER BY 1;

-- 3.13 Cohorts: customers grouped by the year of their first purchase, and how many came back.
--      (Older cohorts have had longer to return: read with care.)
WITH f AS (SELECT customer_id, MIN(sale_date) AS first_date FROM sales GROUP BY customer_id),
     n AS (SELECT customer_id, COUNT(*) AS occasions FROM v_purchase_events GROUP BY customer_id)
SELECT EXTRACT(YEAR FROM f.first_date)::int AS cohort_year,
       COUNT(*)                                          AS customers,
       COUNT(*) FILTER (WHERE n.occasions > 1)           AS came_back,
       ROUND(100.0 * COUNT(*) FILTER (WHERE n.occasions > 1) / COUNT(*), 1) AS came_back_pct
FROM f
JOIN n USING (customer_id)
GROUP BY 1
ORDER BY 1;

-- TRY NEXT: Which customer city buys the most EVs? Do customers buy at a dealership in their own
-- city (compare customer_city vs dealership_city after cleaning the city names, see 8.2)?
-- Which "At risk" customers should marketing call first?


-- ====================================================================
-- CATEGORY 4: SALES TEAM PERFORMANCE
-- "The Sales Director is preparing bonuses and wants to see who is
--  really hitting target."
-- ====================================================================

-- 4.1  Top 10 salespeople: revenue AND the margin they gave away to get it.
SELECT salesperson, dealership_name,
       COUNT(*)           AS units,
       SUM(sale_price)    AS revenue,
       ROUND(100.0 * SUM(discount_amount) / SUM(list_price), 2) AS avg_discount_pct,
       ROUND(100.0 * SUM(gross_profit) / SUM(sale_price), 1)    AS margin_pct
FROM v_sales_detail
GROUP BY employee_id, salesperson, dealership_name
ORDER BY revenue DESC
LIMIT 10;

-- 4.2  Target hit rate WITH zero-sale months counted as misses (calendar spine via generate_series).
--      Compare the two hit-rate columns: ignoring empty months flatters everyone.
WITH bounds AS (
  SELECT DATE_TRUNC('month', MIN(sale_date))::date AS first_month,
         DATE_TRUNC('month', MAX(sale_date))::date AS last_month
  FROM sales
),
spine AS (
  SELECT e.employee_id, e.full_name, e.monthly_target_units,
         generate_series(GREATEST(DATE_TRUNC('month', e.hire_date)::date, b.first_month),
                         b.last_month, INTERVAL '1 month')::date AS month
  FROM employees e
  CROSS JOIN bounds b
  WHERE e.role <> 'Sales Manager'
),
monthly AS (
  SELECT employee_id, sale_month AS month, COUNT(*) AS units
  FROM v_sales_detail
  GROUP BY employee_id, sale_month
)
SELECT sp.full_name, sp.monthly_target_units AS target,
       COUNT(*)           AS months_employed,
       COUNT(mo.units)    AS months_with_sales,
       COUNT(*) FILTER (WHERE COALESCE(mo.units, 0) >= sp.monthly_target_units) AS months_target_hit,
       ROUND(100.0 * COUNT(*) FILTER (WHERE COALESCE(mo.units, 0) >= sp.monthly_target_units) / COUNT(*), 1) AS hit_rate_all_months_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE mo.units >= sp.monthly_target_units) / NULLIF(COUNT(mo.units), 0), 1) AS hit_rate_active_months_pct
FROM spine sp
LEFT JOIN monthly mo ON mo.employee_id = sp.employee_id AND mo.month = sp.month
GROUP BY sp.employee_id, sp.full_name, sp.monthly_target_units
ORDER BY hit_rate_all_months_pct DESC
LIMIT 15;

-- 4.3  New-hire ramp-up: average units per month by months since hire (people hired during the data period).
WITH bounds AS (
  SELECT DATE_TRUNC('month', MIN(sale_date))::date AS first_month,
         DATE_TRUNC('month', MAX(sale_date))::date AS last_month
  FROM sales
),
spine AS (
  SELECT e.employee_id, e.hire_date,
         generate_series(DATE_TRUNC('month', e.hire_date)::date, b.last_month, INTERVAL '1 month')::date AS month
  FROM employees e
  CROSS JOIN bounds b
  WHERE e.role <> 'Sales Manager' AND e.hire_date >= b.first_month
),
monthly AS (
  SELECT employee_id, sale_month AS month, COUNT(*) AS units
  FROM v_sales_detail
  GROUP BY employee_id, sale_month
),
tenure AS (
  SELECT sp.employee_id, sp.month,
         (EXTRACT(YEAR FROM sp.month) * 12 + EXTRACT(MONTH FROM sp.month))
       - (EXTRACT(YEAR FROM sp.hire_date) * 12 + EXTRACT(MONTH FROM sp.hire_date)) AS months_since_hire
  FROM spine sp
)
SELECT CASE WHEN t.months_since_hire < 3  THEN '1) 0-2 months'
            WHEN t.months_since_hire < 6  THEN '2) 3-5 months'
            WHEN t.months_since_hire < 12 THEN '3) 6-11 months'
            ELSE '4) 12+ months' END AS tenure,
       COUNT(*)                              AS employee_months,
       ROUND(AVG(COALESCE(mo.units, 0)), 2)  AS avg_units_per_month
FROM tenure t
LEFT JOIN monthly mo ON mo.employee_id = t.employee_id AND mo.month = t.month
GROUP BY 1
ORDER BY 1;

-- 4.4  Which sales channel gives the biggest discounts, and what happens to margin?
SELECT sales_channel,
       COUNT(*)                                                  AS units,
       ROUND(AVG(discount_amount))                               AS avg_discount,
       ROUND(100.0 * SUM(discount_amount) / SUM(list_price), 2)  AS discount_pct_of_list,
       ROUND(100.0 * SUM(gross_profit) / SUM(sale_price), 1)     AS margin_pct
FROM v_sales_detail
GROUP BY sales_channel
ORDER BY discount_pct_of_list DESC;

-- 4.5  Do discounts "work"? Look at the AGE of the car when it sold. Discounts are mostly used to
--      clear old stock, so bigger discounts show up on cars that sat longer (a symptom, not a cure).
SELECT CASE WHEN days_to_sell <= 30  THEN '1) sold in 0-30 days'
            WHEN days_to_sell <= 90  THEN '2) 31-90 days'
            WHEN days_to_sell <= 180 THEN '3) 91-180 days'
            ELSE '4) 180+ days' END AS stock_age_when_sold,
       COUNT(*) AS units,
       ROUND(100.0 * SUM(discount_amount) / SUM(list_price), 2) AS discount_pct,
       ROUND(100.0 * SUM(gross_profit) / SUM(sale_price), 1)    AS margin_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE gross_profit < 0) / COUNT(*), 1) AS loss_deal_pct
FROM v_sales_detail
GROUP BY 1
ORDER BY 1;

-- 4.6  Manager view: each manager's team units and revenue (self-join on manager_id).
SELECT mgr.full_name AS manager, dl.dealership_name,
       COUNT(s.sale_id)  AS team_units,
       SUM(s.sale_price) AS team_revenue
FROM employees mgr
JOIN dealerships dl ON dl.dealership_id = mgr.dealership_id
JOIN employees e    ON e.manager_id = mgr.employee_id
JOIN sales s        ON s.employee_id = e.employee_id
GROUP BY mgr.employee_id, mgr.full_name, dl.dealership_name
ORDER BY team_revenue DESC;

-- 4.7  Top 3 salespeople inside EACH dealership.
SELECT *
FROM (
  SELECT dealership_name, salesperson, COUNT(*) AS units, SUM(sale_price) AS revenue,
         RANK() OVER (PARTITION BY dealership_name ORDER BY SUM(sale_price) DESC) AS rnk
  FROM v_sales_detail
  GROUP BY dealership_name, employee_id, salesperson
) t
WHERE rnk <= 3
ORDER BY dealership_name, rnk;

-- 4.8  Do top sellers just discount more? Correlation between units sold and average discount %.
--      Rule of thumb: under 0.3 = weak, 0.3-0.7 = moderate, over 0.7 = strong.
--      A weak value means discounting explains only a little of who sells more.
WITH per AS (
  SELECT employee_id, COUNT(*) AS units, 100.0 * SUM(discount_amount) / SUM(list_price) AS disc_pct
  FROM v_sales_detail
  GROUP BY employee_id
)
SELECT ROUND(CORR(units, disc_pct)::numeric, 2) AS correlation_units_vs_discount
FROM per;

-- TRY NEXT: Which salespeople are improving fastest (last 6 months vs the 6 before)?
-- Which channel does each dealership rely on most? Do senior staff sell higher-priced cars?


-- ====================================================================
-- CATEGORY 5: INVENTORY & PRODUCT MIX
-- "Operations wants to know what to stock, what is stuck on the lot,
--  and where we are losing money."
-- ====================================================================

-- 5.1  Stock position: status, number of cars and capital (cost) in each.
SELECT status, COUNT(*) AS cars, SUM(cost_price) AS capital_at_cost
FROM vehicles
GROUP BY status
ORDER BY cars DESC;

-- 5.2  Inventory aging buckets for unsold cars (as of the data cut-off, no hardcoded date).
SELECT CASE WHEN age <= 30  THEN '1) 0-30 days'
            WHEN age <= 90  THEN '2) 31-90 days'
            WHEN age <= 180 THEN '3) 91-180 days'
            WHEN age <= 365 THEN '4) 181-365 days'
            ELSE '5) over 1 year' END AS age_bucket,
       COUNT(*)        AS cars,
       SUM(cost_price) AS capital_tied_up,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_stock
FROM (
  SELECT v.cost_price, p.as_of_date - v.arrival_date AS age
  FROM vehicles v
  CROSS JOIN v_params p
  WHERE v.status IN ('In Stock', 'Reserved')
) t
GROUP BY 1
ORDER BY 1;

-- 5.3  Dead stock: the 15 oldest unsold cars (over 180 days).
SELECT b.brand_name, m.model_name, dl.dealership_name, v.arrival_date,
       p.as_of_date - v.arrival_date AS days_in_stock, v.cost_price
FROM vehicles v
JOIN car_models m   ON m.model_id = v.model_id
JOIN brands b       ON b.brand_id = m.brand_id
JOIN dealerships dl ON dl.dealership_id = v.dealership_id
CROSS JOIN v_params p
WHERE v.status = 'In Stock' AND p.as_of_date - v.arrival_date > 180
ORDER BY days_in_stock DESC
LIMIT 15;

-- 5.4  Capital tied up per dealership and how much of it is older than 90 days.
SELECT dl.dealership_name,
       COUNT(*)          AS unsold_cars,
       SUM(v.cost_price) AS capital_tied_up,
       COUNT(*) FILTER (WHERE p.as_of_date - v.arrival_date > 90) AS cars_over_90d,
       ROUND(100.0 * COUNT(*) FILTER (WHERE p.as_of_date - v.arrival_date > 90) / COUNT(*), 1) AS pct_over_90d
FROM vehicles v
JOIN dealerships dl ON dl.dealership_id = v.dealership_id
CROSS JOIN v_params p
WHERE v.status IN ('In Stock', 'Reserved')
GROUP BY dl.dealership_name
ORDER BY capital_tied_up DESC;

-- 5.5  Slowest-selling models (needs 20+ sales so one odd car cannot mislead). Median beats average here.
SELECT brand_name, model_name,
       COUNT(*) AS units,
       ROUND(AVG(days_to_sell), 1) AS avg_days_to_sell,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY days_to_sell)::numeric, 1) AS median_days_to_sell
FROM v_sales_detail
GROUP BY brand_name, model_name
HAVING COUNT(*) >= 20
ORDER BY median_days_to_sell DESC
LIMIT 10;

-- 5.6  Months of supply per model: cars in stock / average monthly sales (last 6 months).
--      Blank months_of_supply = in stock but NOT selling at all: stop ordering.
WITH recent AS (
  SELECT d.model_id, COUNT(*) / 6.0 AS avg_monthly_sales
  FROM v_sales_detail d
  CROSS JOIN v_params p
  WHERE d.sale_date > p.as_of_date - INTERVAL '6 months'
  GROUP BY d.model_id
),
stock AS (
  SELECT model_id, COUNT(*) AS in_stock
  FROM vehicles
  WHERE status IN ('In Stock', 'Reserved')
  GROUP BY model_id
)
SELECT b.brand_name, m.model_name, s.in_stock,
       ROUND(r.avg_monthly_sales, 1)                        AS avg_monthly_sales,
       ROUND(s.in_stock / NULLIF(r.avg_monthly_sales, 0), 1) AS months_of_supply
FROM stock s
JOIN car_models m ON m.model_id = s.model_id
JOIN brands b     ON b.brand_id = m.brand_id
LEFT JOIN recent r ON r.model_id = s.model_id
ORDER BY months_of_supply DESC NULLS FIRST
LIMIT 12;

-- 5.7  Top 10 best-sellers with profit per car (volume is not the same as profit).
SELECT brand_name, model_name,
       COUNT(*) AS units,
       ROUND(AVG(gross_profit)) AS avg_profit_per_car,
       SUM(gross_profit)        AS total_profit
FROM v_sales_detail
GROUP BY brand_name, model_name
ORDER BY units DESC
LIMIT 10;

-- 5.8  Colour preferences: share of units per colour, EV vs non-EV.
SELECT color,
       COUNT(*) AS units,
       ROUND(100.0 * COUNT(*) FILTER (WHERE fuel_type <> 'Electric') / SUM(COUNT(*) FILTER (WHERE fuel_type <> 'Electric')) OVER (), 1) AS non_ev_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE fuel_type  = 'Electric') / SUM(COUNT(*) FILTER (WHERE fuel_type  = 'Electric')) OVER (), 1) AS ev_pct
FROM v_sales_detail
GROUP BY color
ORDER BY units DESC;

-- 5.9  Loss-making deals (sold BELOW cost): what do they have in common?
SELECT brand_name,
       COUNT(*)                        AS loss_deals,
       ROUND(AVG(days_to_sell))        AS avg_days_in_stock,
       ROUND(AVG(discount_pct), 1)     AS avg_discount_pct,
       SUM(-gross_profit)              AS total_loss
FROM v_sales_detail
WHERE gross_profit < 0
GROUP BY brand_name
ORDER BY total_loss DESC;

-- 5.10 Loss RATE per brand (loss deals / all deals), not just the count.
SELECT brand_name,
       COUNT(*) AS deals,
       COUNT(*) FILTER (WHERE gross_profit < 0) AS loss_deals,
       ROUND(100.0 * COUNT(*) FILTER (WHERE gross_profit < 0) / COUNT(*), 1) AS loss_rate_pct
FROM v_sales_detail
GROUP BY brand_name
ORDER BY loss_rate_pct DESC;

-- TRY NEXT: Which dealership's old stock would sell if moved to a dealership where that model
-- sells fast? What discount would clear every car over 180 days and still break even?


-- ====================================================================
-- CATEGORY 6: PAYMENT & FINANCING
-- "Finance wants to understand how customers pay and how much
--  exposure we have with each lender."
-- ====================================================================

-- 6.1  Payment method mix per year: is credit growing?
SELECT sale_year,
       COUNT(*) AS cars,
       ROUND(100.0 * COUNT(*) FILTER (WHERE payment_method = 'Cash')   / COUNT(*), 1) AS cash_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE payment_method = 'Credit') / COUNT(*), 1) AS credit_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE payment_method = 'Lease')  / COUNT(*), 1) AS lease_pct
FROM v_sales_detail
GROUP BY sale_year
ORDER BY sale_year;

-- 6.2  Lender scoreboard: loans, exposure, approval rate, down payment %, tenor, rate.
--      (Pending loans only exist for the most recent sales, so approval rate looks high by design.)
SELECT lender,
       COUNT(*)           AS loans,
       SUM(loan_amount)   AS total_loan_amount,
       ROUND(100.0 * COUNT(*) FILTER (WHERE approval_status = 'Approved') / COUNT(*), 1) AS approval_rate_pct,
       ROUND(AVG(100.0 * down_payment / (down_payment + loan_amount)), 1) AS avg_down_payment_pct,
       ROUND(AVG(tenor_months), 1)      AS avg_tenor_months,
       ROUND(AVG(interest_rate_pct), 2) AS avg_rate_pct
FROM financing
GROUP BY lender
ORDER BY total_loan_amount DESC;

-- 6.3  Do EV buyers get cheaper rates than other fuel types?
SELECT d.fuel_type,
       COUNT(*)                          AS loans,
       ROUND(AVG(f.interest_rate_pct), 2) AS avg_rate_pct,
       ROUND(AVG(f.tenor_months), 1)      AS avg_tenor_months
FROM financing f
JOIN v_sales_detail d USING (sale_id)
GROUP BY d.fuel_type
ORDER BY avg_rate_pct;

-- 6.4  Monthly instalment with the standard annuity formula: P * r / (1 - (1+r)^-n), r = annual rate / 12.
SELECT d.sale_id, d.customer, d.model_name, f.loan_amount, f.tenor_months, f.interest_rate_pct,
       ROUND(f.loan_amount * (f.interest_rate_pct / 1200.0)
             / (1 - POWER(1 + f.interest_rate_pct / 1200.0, -f.tenor_months))) AS monthly_instalment
FROM financing f
JOIN v_sales_detail d USING (sale_id)
ORDER BY monthly_instalment DESC
LIMIT 10;

-- 6.5  Down payment % by price band: do expensive cars need bigger down payments?
SELECT CASE WHEN d.sale_price < 250000000 THEN '1) under 250M'
            WHEN d.sale_price < 500000000 THEN '2) 250-500M'
            ELSE '3) 500M and above' END AS price_band,
       COUNT(*) AS loans,
       ROUND(AVG(100.0 * f.down_payment / (f.down_payment + f.loan_amount)), 1) AS avg_down_payment_pct,
       ROUND(AVG(f.tenor_months), 1) AS avg_tenor_months
FROM financing f
JOIN v_sales_detail d USING (sale_id)
GROUP BY 1
ORDER BY 1;

-- 6.6  Loans still pending approval, oldest first (days waiting since the sale).
SELECT f.financing_id, d.customer, f.lender, f.loan_amount, d.sale_date,
       p.as_of_date - d.sale_date AS days_waiting
FROM financing f
JOIN v_sales_detail d USING (sale_id)
CROSS JOIN v_params p
WHERE f.approval_status = 'Pending'
ORDER BY days_waiting DESC, f.loan_amount DESC
LIMIT 20;

-- 6.7  Financing penetration: what % of cars are financed, by customer type?
SELECT d.customer_type,
       COUNT(*)                   AS cars,
       COUNT(f.financing_id)      AS financed,
       ROUND(100.0 * COUNT(f.financing_id) / COUNT(*), 1) AS financed_pct
FROM v_sales_detail d
LEFT JOIN financing f USING (sale_id)
GROUP BY d.customer_type;

-- TRY NEXT: Which lender is cheapest for Toyota buyers? Total monthly instalment obligations
-- per lender? Does a longer tenor go with a higher interest rate?


-- ====================================================================
-- CATEGORY 7: AFTER-SALES SERVICE
-- "The service department wants to know what repairs cost and which
--  brands bring customers back to the workshop."
-- ====================================================================

-- 7.1  Service revenue and repair share per brand.
SELECT d.brand_name,
       COUNT(*)       AS visits,
       SUM(sr.cost)   AS service_revenue,
       COUNT(*) FILTER (WHERE sr.service_type = 'Repair') AS repairs,
       ROUND(100.0 * COUNT(*) FILTER (WHERE sr.service_type = 'Repair') / COUNT(*), 1) AS repair_pct
FROM service_records sr
JOIN v_sales_detail d USING (sale_id)
GROUP BY d.brand_name
ORDER BY repair_pct DESC;

-- 7.2  Never-serviced cars: overall vs only cars sold 12+ months ago (recent buyers had no time to come in).
SELECT 'All cars' AS scope,
       COUNT(*) AS cars_sold,
       COUNT(*) FILTER (WHERE r.sale_id IS NULL) AS never_serviced,
       ROUND(100.0 * COUNT(*) FILTER (WHERE r.sale_id IS NULL) / COUNT(*), 1) AS pct_never_serviced
FROM v_sales_detail d
LEFT JOIN (SELECT DISTINCT sale_id FROM service_records) r ON r.sale_id = d.sale_id
UNION ALL
SELECT 'Sold 12+ months before cut-off',
       COUNT(*),
       COUNT(*) FILTER (WHERE r.sale_id IS NULL),
       ROUND(100.0 * COUNT(*) FILTER (WHERE r.sale_id IS NULL) / COUNT(*), 1)
FROM v_sales_detail d
CROSS JOIN v_params p
LEFT JOIN (SELECT DISTINCT sale_id FROM service_records) r ON r.sale_id = d.sale_id
WHERE d.sale_date <= p.as_of_date - INTERVAL '12 months';

-- 7.3  Fair comparison between brands: service visits and cost per CAR-YEAR owned.
WITH owned AS (
  SELECT d.brand_name, SUM((p.as_of_date - d.sale_date) / 365.0) AS car_years
  FROM v_sales_detail d
  CROSS JOIN v_params p
  GROUP BY d.brand_name
),
cost AS (
  SELECT d.brand_name, COUNT(*) AS visits, SUM(sr.cost) AS service_cost
  FROM service_records sr
  JOIN v_sales_detail d USING (sale_id)
  GROUP BY d.brand_name
)
SELECT o.brand_name, ROUND(o.car_years) AS car_years, c.visits,
       ROUND(c.visits / o.car_years, 2)       AS visits_per_car_year,
       ROUND(c.service_cost / o.car_years)    AS cost_per_car_year
FROM owned o
JOIN cost c USING (brand_name)
ORDER BY cost_per_car_year DESC;

-- 7.4  Average cost by service type.
SELECT service_type, COUNT(*) AS visits, ROUND(AVG(cost)) AS avg_cost, SUM(cost) AS total_cost
FROM service_records
GROUP BY service_type
ORDER BY avg_cost DESC;

-- 7.5  Do cars need more repairs as they age? Repair % by visit number.
WITH v AS (
  SELECT sale_id, service_type,
         ROW_NUMBER() OVER (PARTITION BY sale_id ORDER BY service_date) AS visit_no
  FROM service_records
)
SELECT visit_no, COUNT(*) AS visits,
       ROUND(100.0 * COUNT(*) FILTER (WHERE service_type = 'Repair') / COUNT(*), 1) AS repair_pct
FROM v
WHERE visit_no <= 8
GROUP BY visit_no
ORDER BY visit_no;

-- 7.6  Models with the highest repair share (40+ visits so the sample is fair).
SELECT d.brand_name, d.model_name,
       COUNT(*) AS visits,
       ROUND(100.0 * COUNT(*) FILTER (WHERE sr.service_type = 'Repair') / COUNT(*), 1) AS repair_pct,
       ROUND(AVG(sr.cost) FILTER (WHERE sr.service_type = 'Repair')) AS avg_repair_cost
FROM service_records sr
JOIN v_sales_detail d USING (sale_id)
GROUP BY d.brand_name, d.model_name
HAVING COUNT(*) >= 40
ORDER BY repair_pct DESC
LIMIT 10;

-- TRY NEXT: Warranty and recall cost the company money: estimate it per brand. Which dealership's
-- customers skip servicing the most? (Hint: link sale -> vehicle -> dealership.)


-- ====================================================================
-- CATEGORY 8: DATA QUALITY & REPORTING
-- "Before we trust any dashboard, check the data. Then package the
--  numbers so the BI team can reuse them."
-- ====================================================================

-- 8.1  One-page data-quality report. ERROR = must fix. WARNING = clean before reporting.
WITH checks AS (
  SELECT 'Sale dated before the car arrived' AS check_name, 'ERROR' AS severity, COUNT(*) AS bad_rows
  FROM sales s JOIN vehicles v ON v.vehicle_id = s.vehicle_id WHERE s.sale_date < v.arrival_date
  UNION ALL
  SELECT 'Vehicle status disagrees with sales table', 'ERROR', COUNT(*)
  FROM vehicles v LEFT JOIN sales s ON s.vehicle_id = v.vehicle_id
  WHERE (v.status = 'Sold') <> (s.sale_id IS NOT NULL)
  UNION ALL
  SELECT 'Sale before salesperson was hired', 'ERROR', COUNT(*)
  FROM sales s JOIN employees e ON e.employee_id = s.employee_id WHERE s.sale_date < e.hire_date
  UNION ALL
  SELECT 'Sale before customer registered', 'ERROR', COUNT(*)
  FROM sales s JOIN customers c ON c.customer_id = s.customer_id WHERE s.sale_date < c.registered_date
  UNION ALL
  SELECT 'Salesperson from a different dealership than the car', 'ERROR', COUNT(*)
  FROM sales s JOIN vehicles v ON v.vehicle_id = s.vehicle_id JOIN employees e ON e.employee_id = s.employee_id
  WHERE e.dealership_id <> v.dealership_id
  UNION ALL
  SELECT 'sale_price <> list_price - discount', 'ERROR', COUNT(*)
  FROM sales s JOIN vehicles v ON v.vehicle_id = s.vehicle_id WHERE s.sale_price <> v.list_price - s.discount_amount
  UNION ALL
  SELECT 'Duplicate VINs', 'ERROR', COUNT(*) FROM (SELECT vin FROM vehicles GROUP BY vin HAVING COUNT(*) > 1) t
  UNION ALL
  SELECT 'Zero or negative prices', 'ERROR', COUNT(*) FROM sales WHERE sale_price <= 0
  UNION ALL
  SELECT 'Customers missing email', 'WARNING', COUNT(*) FROM customers WHERE email IS NULL
  UNION ALL
  SELECT 'Customers missing phone', 'WARNING', COUNT(*) FROM customers WHERE phone IS NULL
  UNION ALL
  SELECT 'Customer city spelled inconsistently', 'WARNING', COUNT(*) FROM customers WHERE city <> INITCAP(TRIM(city))
  UNION ALL
  SELECT 'Deals sold below cost (business review)', 'WARNING', COUNT(*)
  FROM sales s JOIN vehicles v ON v.vehicle_id = s.vehicle_id WHERE s.sale_price < v.cost_price
)
SELECT check_name, severity, bad_rows,
       CASE WHEN bad_rows = 0 THEN 'PASS' ELSE severity END AS result
FROM checks
ORDER BY CASE WHEN bad_rows = 0 THEN 2 ELSE 1 END, severity, check_name;

-- 8.2  Find the messy city names (extra spaces, wrong CASE) and the cleaned version.
SELECT city AS raw_city, '[' || city || ']' AS visible_spaces,
       COUNT(*) AS customers, INITCAP(TRIM(city)) AS cleaned_city
FROM customers
WHERE city <> INITCAP(TRIM(city))
GROUP BY city
ORDER BY cleaned_city;

-- 8.3  Why it matters: grouping by the RAW city splits one city into several rows.
SELECT city AS raw_city, COUNT(*) AS customers FROM customers GROUP BY city ORDER BY LOWER(TRIM(city)), city;
-- ...and grouping by the CLEANED city fixes it:
SELECT INITCAP(TRIM(city)) AS city, COUNT(*) AS customers FROM customers GROUP BY 1 ORDER BY customers DESC;
-- To fix it permanently (left commented so this file never changes your data by accident):
-- UPDATE customers SET city = INITCAP(TRIM(city)) WHERE city <> INITCAP(TRIM(city));

-- 8.4  Missing contact details by customer type: who can marketing actually reach?
SELECT customer_type,
       COUNT(*) AS customers,
       COUNT(*) FILTER (WHERE email IS NULL) AS no_email,
       COUNT(*) FILTER (WHERE phone IS NULL) AS no_phone,
       COUNT(*) FILTER (WHERE email IS NULL AND phone IS NULL) AS unreachable
FROM customers
GROUP BY customer_type;

-- 8.5  Reconciliation: do the numbers add up no matter how you cut them?
--      If the view silently dropped rows (a bad JOIN), view_total would be smaller than raw_total.
SELECT *, (raw_total = view_total AND raw_total = by_brand AND raw_total = by_dealership) AS all_match
FROM (
  SELECT (SELECT SUM(sale_price) FROM sales)                                                        AS raw_total,
         (SELECT SUM(sale_price) FROM v_sales_detail)                                               AS view_total,
         (SELECT SUM(r) FROM (SELECT SUM(sale_price) AS r FROM v_sales_detail GROUP BY brand_name) t)       AS by_brand,
         (SELECT SUM(r) FROM (SELECT SUM(sale_price) AS r FROM v_sales_detail GROUP BY dealership_name) t)  AS by_dealership
) x;

-- 8.6  Using the reporting view: profit by country of origin and segment (a short query now).
SELECT country_of_origin, segment, COUNT(*) AS units, SUM(gross_profit) AS profit
FROM v_sales_detail
GROUP BY country_of_origin, segment
ORDER BY profit DESC;

-- 8.7  Speed: PostgreSQL does NOT index foreign-key columns automatically. Add indexes, then compare.
CREATE INDEX IF NOT EXISTS idx_sales_customer    ON sales (customer_id);
CREATE INDEX IF NOT EXISTS idx_sales_employee    ON sales (employee_id);
CREATE INDEX IF NOT EXISTS idx_sales_date        ON sales (sale_date);
CREATE INDEX IF NOT EXISTS idx_vehicles_model    ON vehicles (model_id);
CREATE INDEX IF NOT EXISTS idx_vehicles_dealer   ON vehicles (dealership_id);
CREATE INDEX IF NOT EXISTS idx_service_sale      ON service_records (sale_id);
CREATE INDEX IF NOT EXISTS idx_models_brand      ON car_models (brand_id);
CREATE INDEX IF NOT EXISTS idx_employees_dealer  ON employees (dealership_id);

-- Look at the plan: "Index Scan" / "Bitmap Index Scan" = index used; "Seq Scan" = full table read.
EXPLAIN ANALYZE
SELECT brand_name, SUM(sale_price)
FROM v_sales_detail
WHERE sale_date >= DATE '2025-01-01' AND sale_date < DATE '2025-04-01'
GROUP BY brand_name;

-- TRY NEXT: Add a CHECK constraint so sale_price can never be negative. Write a query that finds
-- customers who may be duplicates (same name + same birth_date). Schedule 8.1 as a daily check.