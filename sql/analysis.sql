-- Olist e-commerce analysis (SQLite)
-- Business question: what most damages customer satisfaction, and where should the business act first?
-- Scope: delivered orders purchased January 2017 to August 2018, the complete months in the data.
-- Currency: Brazilian reais (BRL). Revenue means item price and excludes freight.
-- "Late" means delivered on a later calendar day than the date promised to the customer.

-- @name: 01_scope_check
-- How many orders are in scope, and how many delivered orders lack a delivery date?
SELECT COUNT(*) AS all_orders,
       SUM(order_status = 'delivered') AS delivered_orders,
       SUM(order_status = 'delivered' AND order_delivered_customer_date IS NULL) AS delivered_no_date,
       SUM(order_status = 'delivered' AND order_delivered_customer_date IS NOT NULL
           AND substr(order_purchase_timestamp,1,7) BETWEEN '2017-01' AND '2018-08') AS orders_in_scope
FROM orders;

-- @name: 02_monthly_revenue
-- Monthly revenue and growth. LAG reads the previous month's value.
WITH base AS (
  SELECT o.order_id, substr(o.order_purchase_timestamp,1,7) AS month, SUM(i.price) AS revenue
  FROM orders o JOIN order_items i USING (order_id)
  WHERE o.order_status = 'delivered' AND o.order_delivered_customer_date IS NOT NULL
    AND substr(o.order_purchase_timestamp,1,7) BETWEEN '2017-01' AND '2018-08'
  GROUP BY o.order_id
), monthly AS (
  SELECT month, COUNT(*) AS orders, ROUND(SUM(revenue),2) AS revenue FROM base GROUP BY month
)
SELECT month, orders, revenue, ROUND(revenue / orders, 2) AS avg_order_value,
       ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month)) / LAG(revenue) OVER (ORDER BY month), 1) AS growth_pct
FROM monthly ORDER BY month;

-- @name: 03_top_categories
-- Top 10 categories, with each one's share of all revenue. Starting from order_items avoids double counting.
WITH cat AS (
  SELECT COALESCE(t.product_category_name_english, p.product_category_name, 'unknown') AS category,
         COUNT(DISTINCT i.order_id) AS orders, SUM(i.price) AS revenue
  FROM order_items i
  JOIN orders o USING (order_id)
  LEFT JOIN products p USING (product_id)
  LEFT JOIN product_category_name_translation t USING (product_category_name)
  WHERE o.order_status = 'delivered' AND o.order_delivered_customer_date IS NOT NULL
    AND substr(o.order_purchase_timestamp,1,7) BETWEEN '2017-01' AND '2018-08'
  GROUP BY 1
), ranked AS (
  SELECT category, orders, ROUND(revenue,2) AS revenue,
         ROUND(100.0 * revenue / SUM(revenue) OVER (), 1) AS revenue_share_pct,
         RANK() OVER (ORDER BY revenue DESC) AS rnk
  FROM cat
)
SELECT rnk, category, orders, revenue, revenue_share_pct,
       ROUND(SUM(revenue_share_pct) OVER (ORDER BY rnk), 1) AS cumulative_share_pct
FROM ranked WHERE rnk <= 10 ORDER BY rnk;

-- @name: 04_order_facts_check
-- One row per reviewed order. Some orders have several reviews, so ROW_NUMBER keeps only the latest.
WITH latest_review AS (
  SELECT order_id, review_score,
         ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY review_creation_date DESC, review_answer_timestamp DESC) AS rn
  FROM order_reviews
), facts AS (
  SELECT o.order_id, r.review_score,
         julianday(date(o.order_delivered_customer_date)) - julianday(date(o.order_estimated_delivery_date)) AS days_vs_promise
  FROM orders o JOIN latest_review r ON r.order_id = o.order_id AND r.rn = 1
  WHERE o.order_status = 'delivered' AND o.order_delivered_customer_date IS NOT NULL
    AND substr(o.order_purchase_timestamp,1,7) BETWEEN '2017-01' AND '2018-08'
)
SELECT COUNT(*) AS reviewed_orders, COUNT(DISTINCT order_id) AS distinct_orders,
       ROUND(AVG(review_score),2) AS avg_score, SUM(days_vs_promise > 0) AS late_orders,
       ROUND(100.0 * SUM(days_vs_promise > 0) / COUNT(*), 1) AS late_pct
FROM facts;

-- @name: 05_score_by_timeliness
-- Review score by how late or early the order arrived.
WITH latest_review AS (
  SELECT order_id, review_score,
         ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY review_creation_date DESC, review_answer_timestamp DESC) AS rn
  FROM order_reviews
), facts AS (
  SELECT r.review_score,
         julianday(date(o.order_delivered_customer_date)) - julianday(date(o.order_estimated_delivery_date)) AS d
  FROM orders o JOIN latest_review r ON r.order_id = o.order_id AND r.rn = 1
  WHERE o.order_status = 'delivered' AND o.order_delivered_customer_date IS NOT NULL
    AND substr(o.order_purchase_timestamp,1,7) BETWEEN '2017-01' AND '2018-08'
)
SELECT CASE WHEN d <= 0 THEN '1 On time or early'
            WHEN d <= 3 THEN '2 Late 1-3 days'
            WHEN d <= 7 THEN '3 Late 4-7 days'
            WHEN d <= 14 THEN '4 Late 8-14 days'
            ELSE '5 Late 15+ days' END AS timeliness,
       COUNT(*) AS orders, ROUND(AVG(review_score),2) AS avg_score,
       ROUND(100.0 * SUM(review_score <= 2) / COUNT(*), 1) AS low_score_pct,
       SUM(review_score <= 2) AS low_score_orders
FROM facts GROUP BY 1 ORDER BY 1;

-- @name: 06_late_rate_monthly
-- Late delivery rate by purchase month, to see whether it is a spike or a constant.
SELECT substr(order_purchase_timestamp,1,7) AS month, COUNT(*) AS orders,
       ROUND(100.0 * SUM(date(order_delivered_customer_date) > date(order_estimated_delivery_date)) / COUNT(*), 1) AS late_pct,
       ROUND(AVG(julianday(order_delivered_customer_date) - julianday(order_purchase_timestamp)), 1) AS avg_days_to_deliver
FROM orders
WHERE order_status = 'delivered' AND order_delivered_customer_date IS NOT NULL
  AND substr(order_purchase_timestamp,1,7) BETWEEN '2017-01' AND '2018-08'
GROUP BY 1 ORDER BY 1;

-- @name: 07_states
-- Customer states with at least 1,000 orders: late rate and delivery time.
SELECT c.customer_state AS state, COUNT(*) AS orders,
       ROUND(100.0 * SUM(date(o.order_delivered_customer_date) > date(o.order_estimated_delivery_date)) / COUNT(*), 1) AS late_pct,
       ROUND(AVG(julianday(o.order_delivered_customer_date) - julianday(o.order_purchase_timestamp)), 1) AS avg_days_to_deliver
FROM orders o JOIN customers c USING (customer_id)
WHERE o.order_status = 'delivered' AND o.order_delivered_customer_date IS NOT NULL
  AND substr(o.order_purchase_timestamp,1,7) BETWEEN '2017-01' AND '2018-08'
GROUP BY 1 HAVING COUNT(*) >= 1000 ORDER BY late_pct DESC;

-- @name: 08_late_stage
-- Late orders: was the seller slow to hand over, or was the carrier slow after handover?
-- A seller miss means handover to the carrier after the seller's shipping limit date.
WITH o2 AS (
  SELECT o.order_id,
         date(o.order_delivered_customer_date) > date(o.order_estimated_delivery_date) AS late,
         MAX(date(o.order_delivered_carrier_date) > date(i.shipping_limit_date)) AS seller_missed
  FROM orders o JOIN order_items i USING (order_id)
  WHERE o.order_status = 'delivered' AND o.order_delivered_customer_date IS NOT NULL
    AND o.order_delivered_carrier_date IS NOT NULL
    AND substr(o.order_purchase_timestamp,1,7) BETWEEN '2017-01' AND '2018-08'
  GROUP BY o.order_id
)
SELECT seller_missed, COUNT(*) AS orders, SUM(late) AS late_orders,
       ROUND(100.0 * SUM(late) / COUNT(*), 1) AS late_pct
FROM o2 GROUP BY 1;

-- @name: 09_repeat_customers
-- customer_id changes per order, so customer_unique_id identifies the real person.
WITH per_person AS (
  SELECT c.customer_unique_id, COUNT(*) AS orders
  FROM orders o JOIN customers c USING (customer_id)
  WHERE o.order_status = 'delivered' AND o.order_delivered_customer_date IS NOT NULL
    AND substr(o.order_purchase_timestamp,1,7) BETWEEN '2017-01' AND '2018-08'
  GROUP BY 1
)
SELECT COUNT(*) AS customers, SUM(orders > 1) AS repeat_customers,
       ROUND(100.0 * SUM(orders > 1) / COUNT(*), 2) AS repeat_pct
FROM per_person;

-- @name: 10_seller_concentration
-- How much revenue comes from the top 10% of sellers?
WITH s AS (
  SELECT i.seller_id, SUM(i.price) AS revenue
  FROM order_items i JOIN orders o USING (order_id)
  WHERE o.order_status = 'delivered' AND o.order_delivered_customer_date IS NOT NULL
    AND substr(o.order_purchase_timestamp,1,7) BETWEEN '2017-01' AND '2018-08'
  GROUP BY 1
), t AS (
  SELECT revenue, NTILE(10) OVER (ORDER BY revenue DESC) AS decile FROM s
)
SELECT decile, COUNT(*) AS sellers, ROUND(SUM(revenue),2) AS revenue,
       ROUND(100.0 * SUM(revenue) / (SELECT SUM(revenue) FROM t), 1) AS revenue_share_pct
FROM t GROUP BY 1 ORDER BY 1;
