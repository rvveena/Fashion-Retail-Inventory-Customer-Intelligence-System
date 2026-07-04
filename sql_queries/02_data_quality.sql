-- ================================================================
-- IndiaStyle Retail — Business Intelligence System
-- Layer 2: Data Quality Audit
-- Run BEFORE any analysis. Fix issues before they corrupt results.
-- ================================================================


-- ── CHECK 1: NULL RATE AUDIT ACROSS ALL FACT TABLES ─────────────
-- Executive summary of data completeness

SELECT 'fact_transactions'          AS table_name,
       'customer_id'                AS column_name,
       COUNT(*)                     AS total_rows,
       SUM(CASE WHEN customer_id IS NULL THEN 1 ELSE 0 END)  AS null_count,
       ROUND(100.0 * SUM(CASE WHEN customer_id IS NULL THEN 1 ELSE 0 END)
             / COUNT(*), 2)         AS null_pct
FROM fact_transactions
UNION ALL
SELECT 'fact_transactions', 'payment_method',
       COUNT(*),
       SUM(CASE WHEN payment_method IS NULL THEN 1 ELSE 0 END),
       ROUND(100.0 * SUM(CASE WHEN payment_method IS NULL THEN 1 ELSE 0 END)
             / COUNT(*), 2)
FROM fact_transactions
UNION ALL
SELECT 'dim_products', 'supplier_name',
       COUNT(*),
       SUM(CASE WHEN supplier_name IS NULL THEN 1 ELSE 0 END),
       ROUND(100.0 * SUM(CASE WHEN supplier_name IS NULL THEN 1 ELSE 0 END)
             / COUNT(*), 2)
FROM dim_products
UNION ALL
SELECT 'dim_customers', 'email',
       COUNT(*),
       SUM(CASE WHEN email IS NULL THEN 1 ELSE 0 END),
       ROUND(100.0 * SUM(CASE WHEN email IS NULL THEN 1 ELSE 0 END)
             / COUNT(*), 2)
FROM dim_customers
ORDER BY null_pct DESC;


-- ── CHECK 2: DUPLICATE TRANSACTION DETECTION ─────────────────────
-- Duplicates inflate revenue — must be caught before aggregation

WITH duplicate_check AS (
    SELECT
        transaction_id,
        transaction_date,
        customer_id,
        product_id,
        revenue,
        COUNT(*) OVER (
            PARTITION BY transaction_date, customer_id, product_id, revenue
        ) AS occurrence_count,
        ROW_NUMBER() OVER (
            PARTITION BY transaction_date, customer_id, product_id, revenue
            ORDER BY transaction_id
        ) AS row_rank
    FROM fact_transactions
)
SELECT
    COUNT(*)                                            AS total_transactions,
    SUM(CASE WHEN occurrence_count > 1 THEN 1 ELSE 0 END) AS duplicate_rows,
    SUM(CASE WHEN occurrence_count > 1 AND row_rank > 1
             THEN 1 ELSE 0 END)                        AS rows_to_remove,
    ROUND(100.0 * SUM(CASE WHEN occurrence_count > 1 AND row_rank > 1
             THEN 1 ELSE 0 END) / COUNT(*), 2)         AS duplicate_pct,
    SUM(CASE WHEN occurrence_count > 1 AND row_rank > 1
             THEN revenue ELSE 0 END)                  AS inflated_revenue_inr
FROM duplicate_check;


-- ── CHECK 3: NEGATIVE STOCK ANOMALY DETECTION ────────────────────
-- Negative closing stock = ERP return processing error
-- Must be excluded from inventory health calculations

SELECT
    i.product_id,
    p.product_name,
    p.category,
    i.store_id,
    i.week_date,
    i.closing_stock          AS system_closing_stock,
    i.closing_stock_reported AS reported_closing_stock,
    i.opening_stock,
    i.units_sold,
    'NEGATIVE STOCK ERROR'   AS anomaly_type
FROM fact_inventory i
JOIN dim_products p ON i.product_id = p.product_id
WHERE i.closing_stock_reported < 0
ORDER BY i.closing_stock_reported ASC;


-- ── CHECK 4: PRICE ANOMALY DETECTION ─────────────────────────────
-- Transactions where unit_price > MRP (impossible) or < 50% cost (loss-making)

SELECT
    t.transaction_id,
    t.transaction_date,
    t.product_id,
    p.mrp,
    p.cost_price,
    t.unit_price,
    t.discount_pct,
    CASE
        WHEN t.unit_price > p.mrp
            THEN 'PRICE ABOVE MRP — data error'
        WHEN t.unit_price < p.cost_price * 0.50
            THEN 'PRICE BELOW 50% COST — loss-making transaction'
        WHEN t.discount_pct > 0.70
            THEN 'DISCOUNT > 70% — requires approval check'
    END AS anomaly_flag,
    ROUND(t.unit_price - p.cost_price, 2) AS margin_per_unit
FROM fact_transactions t
JOIN dim_products p ON t.product_id = p.product_id
WHERE t.unit_price > p.mrp
   OR t.unit_price < p.cost_price * 0.50
   OR t.discount_pct > 0.70
ORDER BY anomaly_flag, t.transaction_date;


-- ── CHECK 5: REFERENTIAL INTEGRITY CHECK ─────────────────────────
-- Orphaned records = joins will silently drop rows

SELECT 'Returns with no matching transaction' AS check_name,
       COUNT(*) AS orphan_count
FROM fact_returns r
LEFT JOIN fact_transactions t ON r.transaction_id = t.transaction_id
WHERE t.transaction_id IS NULL
UNION ALL
SELECT 'Transactions with unknown product',
       COUNT(*)
FROM fact_transactions t
LEFT JOIN dim_products p ON t.product_id = p.product_id
WHERE p.product_id IS NULL
UNION ALL
SELECT 'Transactions with unknown store',
       COUNT(*)
FROM fact_transactions t
LEFT JOIN dim_stores s ON t.store_id = s.store_id
WHERE s.store_id IS NULL
UNION ALL
SELECT 'Inventory rows with unknown product',
       COUNT(*)
FROM fact_inventory i
LEFT JOIN dim_products p ON i.product_id = p.product_id
WHERE p.product_id IS NULL;


-- ── CHECK 6: DATE CONSISTENCY ─────────────────────────────────────
-- Return date must always be after transaction date

SELECT
    r.return_id,
    t.transaction_date,
    r.return_date,
    DATEDIFF(day, t.transaction_date, r.return_date) AS days_to_return,
    CASE
        WHEN r.return_date < t.transaction_date
            THEN 'RETURN BEFORE PURCHASE — impossible'
        WHEN DATEDIFF(day, t.transaction_date, r.return_date) > 90
            THEN 'RETURN > 90 DAYS — outside policy window'
    END AS date_anomaly
FROM fact_returns r
JOIN fact_transactions t ON r.transaction_id = t.transaction_id
WHERE r.return_date < t.transaction_date
   OR DATEDIFF(day, t.transaction_date, r.return_date) > 90;


-- ── CLEAN VIEW: deduplicated transactions for analysis ───────────
-- Use this view in all downstream queries instead of raw table

CREATE OR ALTER VIEW vw_clean_transactions AS
WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY transaction_date, product_id,
                            ISNULL(customer_id,'GUEST'), revenue
               ORDER BY transaction_id
           ) AS rn
    FROM fact_transactions
)
SELECT
    transaction_id, transaction_date, customer_id, product_id,
    store_id, quantity, unit_price, discount_pct, revenue, cost,
    payment_method, channel, region
FROM ranked
WHERE rn = 1                          -- remove duplicates
  AND revenue > 0                     -- remove zero-revenue rows
  AND quantity > 0;                   -- remove invalid quantities


-- ── DATA QUALITY SUMMARY REPORT ──────────────────────────────────
SELECT
    'Total transactions (raw)'      AS metric,
    CAST(COUNT(*) AS VARCHAR)        AS value
FROM fact_transactions
UNION ALL
SELECT 'Duplicate transactions removed',
    CAST(COUNT(*) - (SELECT COUNT(*) FROM vw_clean_transactions) AS VARCHAR)
FROM fact_transactions
UNION ALL
SELECT 'Null customer_id (guest checkouts)',
    CAST(SUM(CASE WHEN customer_id IS NULL THEN 1 ELSE 0 END) AS VARCHAR)
FROM fact_transactions
UNION ALL
SELECT 'Negative stock records flagged',
    CAST(COUNT(*) AS VARCHAR)
FROM fact_inventory WHERE closing_stock_reported < 0
UNION ALL
SELECT 'Products with missing supplier',
    CAST(SUM(CASE WHEN supplier_name IS NULL THEN 1 ELSE 0 END) AS VARCHAR)
FROM dim_products;
