-- ================================================================
-- IndiaStyle Retail — Business Intelligence System
-- Layer 3: Core Analytical Queries (9 production-grade queries)
-- Techniques: CTEs, Window Functions, Multi-table JOINs,
--             Subqueries, CASE logic, Date functions
-- ================================================================


-- ══════════════════════════════════════════════════════════════════
-- QUERY 1: Executive Revenue Dashboard
-- Monthly revenue, MoM growth, YoY comparison, margin trend
-- ══════════════════════════════════════════════════════════════════

WITH monthly_revenue AS (
    SELECT
        FORMAT(t.transaction_date, 'yyyy-MM')           AS month,
        YEAR(t.transaction_date)                         AS yr,
        MONTH(t.transaction_date)                        AS mo,
        COUNT(DISTINCT t.transaction_id)                 AS transactions,
        COUNT(DISTINCT t.customer_id)                    AS unique_customers,
        SUM(t.revenue)                                   AS gross_revenue,
        SUM(t.cost)                                      AS total_cost,
        SUM(t.revenue - t.cost)                          AS gross_profit,
        ROUND(AVG(t.discount_pct) * 100, 2)             AS avg_discount_pct
    FROM vw_clean_transactions t
    GROUP BY FORMAT(t.transaction_date, 'yyyy-MM'),
             YEAR(t.transaction_date), MONTH(t.transaction_date)
)
SELECT
    month,
    transactions,
    unique_customers,
    ROUND(gross_revenue, 0)                              AS gross_revenue_inr,
    ROUND(gross_profit, 0)                               AS gross_profit_inr,
    ROUND(gross_profit / NULLIF(gross_revenue,0)*100, 1) AS gross_margin_pct,
    avg_discount_pct,
    -- MoM Growth
    LAG(gross_revenue) OVER (ORDER BY month)             AS prev_month_revenue,
    ROUND(
        (gross_revenue - LAG(gross_revenue) OVER (ORDER BY month)) /
        NULLIF(LAG(gross_revenue) OVER (ORDER BY month), 0) * 100
    , 1)                                                 AS mom_growth_pct,
    -- Rolling 3-month average revenue
    ROUND(AVG(gross_revenue) OVER (
        ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ), 0)                                                AS rolling_3m_avg_revenue,
    -- Cumulative YTD revenue
    SUM(gross_revenue) OVER (
        PARTITION BY yr ORDER BY mo
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                                    AS ytd_revenue
FROM monthly_revenue
ORDER BY month;


-- ══════════════════════════════════════════════════════════════════
-- QUERY 2: Dead Stock & Inventory Health Detection
-- Flags SKUs at risk of full write-off with rupee impact
-- ══════════════════════════════════════════════════════════════════

WITH sku_lifecycle AS (
    SELECT
        i.product_id,
        i.store_id,
        MAX(i.days_on_shelf)                            AS max_days_on_shelf,
        MAX(i.closing_stock)                            AS remaining_units,
        ROUND(
            1.0 - CAST(MAX(i.closing_stock) AS FLOAT) /
            NULLIF(MAX(i.opening_stock), 0), 4
        )                                               AS cumulative_sell_through,
        MAX(i.markdown_pct)                             AS markdown_applied,
        SUM(i.revenue)                                  AS total_revenue_generated
    FROM fact_inventory i
    GROUP BY i.product_id, i.store_id
),
enriched AS (
    SELECT
        sl.*,
        p.product_name,
        p.category,
        p.brand,
        p.season,
        p.cost_price,
        p.mrp,
        p.heat_score,
        s.region,
        ROUND(sl.remaining_units * p.cost_price, 2)    AS stranded_cost_value,
        ROUND(sl.remaining_units * p.mrp * 0.72, 2)    AS potential_recovery_inr,
        CASE
            WHEN sl.cumulative_sell_through < 0.20 AND sl.markdown_applied = 0
                THEN 'CRITICAL — Immediate Markdown'
            WHEN sl.cumulative_sell_through < 0.35 AND sl.markdown_applied = 0
                THEN 'AT-RISK — Markdown Within 2 Weeks'
            WHEN sl.cumulative_sell_through BETWEEN 0.35 AND 0.50
                THEN 'WATCH — Monitor Weekly'
            ELSE 'HEALTHY'
        END                                             AS inventory_status,
        CASE
            WHEN sl.cumulative_sell_through < 0.20 THEN 0.28
            WHEN sl.cumulative_sell_through < 0.35 THEN 0.20
            ELSE 0
        END                                             AS recommended_markdown_pct
    FROM sku_lifecycle sl
    JOIN dim_products p ON sl.product_id = p.product_id
    JOIN dim_stores   s ON sl.store_id   = s.store_id
)
SELECT
    product_id, product_name, category, brand, season, region,
    max_days_on_shelf,
    ROUND(cumulative_sell_through * 100, 1)             AS sell_through_pct,
    remaining_units,
    stranded_cost_value,
    potential_recovery_inr,
    inventory_status,
    ROUND(recommended_markdown_pct * 100, 0)            AS recommended_markdown_pct,
    total_revenue_generated
FROM enriched
WHERE inventory_status != 'HEALTHY'
ORDER BY stranded_cost_value DESC;


-- ══════════════════════════════════════════════════════════════════
-- QUERY 3: Revenue Leakage Reconciliation
-- Orders where revenue captured ≠ expected based on price × qty
-- ══════════════════════════════════════════════════════════════════

WITH expected_vs_actual AS (
    SELECT
        t.transaction_id,
        t.transaction_date,
        t.product_id,
        p.product_name,
        p.category,
        t.store_id,
        s.region,
        t.quantity,
        t.unit_price,
        t.discount_pct,
        t.revenue                                           AS recorded_revenue,
        ROUND(t.unit_price * t.quantity, 2)                 AS expected_revenue,
        ROUND(t.unit_price * t.quantity - t.revenue, 2)     AS revenue_gap,
        t.payment_method,
        t.channel
    FROM vw_clean_transactions t
    JOIN dim_products p ON t.product_id = p.product_id
    JOIN dim_stores   s ON t.store_id   = s.store_id
    WHERE ABS(t.unit_price * t.quantity - t.revenue) > 1   -- ₹1 tolerance
),
leakage_summary AS (
    SELECT
        *,
        CASE
            WHEN revenue_gap > 500  THEN 'HIGH — ₹500+ gap'
            WHEN revenue_gap > 100  THEN 'MEDIUM — ₹100-500 gap'
            WHEN revenue_gap > 0    THEN 'LOW — ₹1-100 gap'
            ELSE 'OVERBILLING — customer charged extra'
        END AS leakage_category
    FROM expected_vs_actual
)
SELECT
    leakage_category,
    COUNT(*)                                                AS transaction_count,
    ROUND(SUM(ABS(revenue_gap)), 0)                        AS total_leakage_inr,
    ROUND(AVG(ABS(revenue_gap)), 0)                        AS avg_gap_per_txn,
    COUNT(DISTINCT store_id)                               AS stores_affected,
    COUNT(DISTINCT product_id)                             AS products_affected
FROM leakage_summary
GROUP BY leakage_category
ORDER BY total_leakage_inr DESC;


-- ══════════════════════════════════════════════════════════════════
-- QUERY 4: RFM Customer Segmentation
-- Recency, Frequency, Monetary scoring for 5,000 customers
-- ══════════════════════════════════════════════════════════════════

WITH customer_metrics AS (
    SELECT
        t.customer_id,
        c.customer_name,
        c.loyalty_tier,
        c.region,
        c.age_group,
        DATEDIFF(day, MAX(t.transaction_date), '2024-09-30')  AS recency_days,
        COUNT(DISTINCT t.transaction_id)                       AS frequency,
        ROUND(SUM(t.revenue), 2)                              AS monetary_value,
        ROUND(AVG(t.revenue), 2)                              AS avg_order_value,
        COUNT(DISTINCT t.product_id)                          AS product_variety
    FROM vw_clean_transactions t
    JOIN dim_customers c ON t.customer_id = c.customer_id
    WHERE t.customer_id IS NOT NULL
    GROUP BY t.customer_id, c.customer_name, c.loyalty_tier,
             c.region, c.age_group
),
rfm_scored AS (
    SELECT
        *,
        NTILE(5) OVER (ORDER BY recency_days DESC)     AS r_score,   -- lower days = higher score
        NTILE(5) OVER (ORDER BY frequency ASC)         AS f_score,
        NTILE(5) OVER (ORDER BY monetary_value ASC)    AS m_score
    FROM customer_metrics
),
rfm_segmented AS (
    SELECT
        *,
        r_score + f_score + m_score                    AS rfm_total,
        CASE
            WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4
                THEN 'Champions'
            WHEN r_score >= 3 AND f_score >= 3 AND m_score >= 3
                THEN 'Loyal Customers'
            WHEN r_score >= 4 AND f_score <= 2
                THEN 'New Customers'
            WHEN r_score <= 2 AND f_score >= 3 AND m_score >= 3
                THEN 'At-Risk — High Value'
            WHEN r_score <= 2 AND f_score <= 2
                THEN 'Lost Customers'
            WHEN m_score >= 4 AND f_score <= 2
                THEN 'Big Spenders — Low Frequency'
            ELSE 'Potential Loyalists'
        END AS rfm_segment
    FROM rfm_scored
)
SELECT
    rfm_segment,
    COUNT(*)                                           AS customer_count,
    ROUND(AVG(recency_days), 0)                       AS avg_recency_days,
    ROUND(AVG(frequency), 1)                          AS avg_orders,
    ROUND(AVG(monetary_value), 0)                     AS avg_ltv_inr,
    ROUND(SUM(monetary_value), 0)                     AS total_segment_revenue_inr,
    ROUND(AVG(avg_order_value), 0)                    AS avg_order_value_inr,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER(), 1) AS segment_pct
FROM rfm_segmented
GROUP BY rfm_segment
ORDER BY total_segment_revenue_inr DESC;


-- ══════════════════════════════════════════════════════════════════
-- QUERY 5: Store Performance Scorecard vs Target
-- Attainment, rank, gap analysis across 35 stores
-- ══════════════════════════════════════════════════════════════════

WITH store_actuals AS (
    SELECT
        t.store_id,
        FORMAT(t.transaction_date, 'yyyy-MM')           AS month,
        SUM(t.revenue)                                  AS actual_revenue,
        COUNT(DISTINCT t.transaction_id)                AS transactions,
        COUNT(DISTINCT t.customer_id)                   AS unique_customers,
        ROUND(SUM(t.revenue - t.cost) /
              NULLIF(SUM(t.revenue), 0) * 100, 2)       AS gross_margin_pct
    FROM vw_clean_transactions t
    GROUP BY t.store_id, FORMAT(t.transaction_date, 'yyyy-MM')
),
store_vs_target AS (
    SELECT
        tgt.store_id,
        s.store_name,
        s.region,
        s.channel,
        tgt.month,
        tgt.target_revenue,
        COALESCE(act.actual_revenue, 0)                 AS actual_revenue,
        COALESCE(act.transactions, 0)                   AS transactions,
        COALESCE(act.gross_margin_pct, 0)               AS gross_margin_pct,
        ROUND(COALESCE(act.actual_revenue,0) -
              tgt.target_revenue, 0)                    AS revenue_gap_inr,
        ROUND(COALESCE(act.actual_revenue,0) /
              NULLIF(tgt.target_revenue,0) * 100, 1)    AS attainment_pct
    FROM fact_sales_targets tgt
    JOIN dim_stores s ON tgt.store_id = s.store_id
    LEFT JOIN store_actuals act ON tgt.store_id = act.store_id
                                AND tgt.month = act.month
)
SELECT
    store_id, store_name, region, channel,
    COUNT(month)                                        AS months_tracked,
    ROUND(SUM(target_revenue), 0)                      AS total_target_inr,
    ROUND(SUM(actual_revenue), 0)                      AS total_actual_inr,
    ROUND(SUM(actual_revenue) /
          NULLIF(SUM(target_revenue),0) * 100, 1)      AS overall_attainment_pct,
    ROUND(SUM(revenue_gap_inr), 0)                     AS cumulative_gap_inr,
    COUNT(CASE WHEN attainment_pct < 80 THEN 1 END)    AS months_below_80pct,
    COUNT(CASE WHEN attainment_pct >= 100 THEN 1 END)  AS months_target_hit,
    RANK() OVER (ORDER BY SUM(actual_revenue) DESC)    AS revenue_rank,
    RANK() OVER (
        ORDER BY SUM(actual_revenue)/NULLIF(SUM(target_revenue),0) DESC
    )                                                   AS attainment_rank
FROM store_vs_target
GROUP BY store_id, store_name, region, channel
ORDER BY overall_attainment_pct DESC;


-- ══════════════════════════════════════════════════════════════════
-- QUERY 6: Return Rate Analysis & Profitability Impact
-- Which products/categories are hurting margin via returns?
-- ══════════════════════════════════════════════════════════════════

WITH sales_summary AS (
    SELECT
        t.product_id,
        p.product_name,
        p.category,
        p.brand,
        COUNT(DISTINCT t.transaction_id)               AS units_sold_txns,
        SUM(t.quantity)                                AS total_units_sold,
        SUM(t.revenue)                                 AS gross_revenue
    FROM vw_clean_transactions t
    JOIN dim_products p ON t.product_id = p.product_id
    GROUP BY t.product_id, p.product_name, p.category, p.brand
),
return_summary AS (
    SELECT
        r.product_id,
        COUNT(*)                                       AS return_count,
        SUM(r.quantity_returned)                       AS units_returned,
        SUM(r.refund_amount)                           AS total_refunds,
        SUM(r.restocking_cost)                         AS total_restocking_cost,
        SUM(CASE WHEN r.resaleable = 0
                 THEN r.refund_amount ELSE 0 END)      AS non_resaleable_loss,
        -- Most common return reason per product
        (SELECT TOP 1 return_reason
         FROM fact_returns r2
         WHERE r2.product_id = r.product_id
         GROUP BY return_reason
         ORDER BY COUNT(*) DESC)                       AS top_return_reason
    FROM fact_returns r
    GROUP BY r.product_id
)
SELECT
    ss.product_id,
    ss.product_name,
    ss.category,
    ss.brand,
    ss.total_units_sold,
    COALESCE(rs.units_returned, 0)                     AS units_returned,
    ROUND(100.0 * COALESCE(rs.units_returned,0) /
          NULLIF(ss.total_units_sold,0), 2)            AS return_rate_pct,
    ROUND(ss.gross_revenue, 0)                         AS gross_revenue_inr,
    ROUND(COALESCE(rs.total_refunds, 0), 0)            AS total_refunds_inr,
    ROUND(COALESCE(rs.total_restocking_cost, 0), 0)    AS restocking_cost_inr,
    ROUND(COALESCE(rs.non_resaleable_loss, 0), 0)      AS non_resaleable_loss_inr,
    ROUND(ss.gross_revenue - COALESCE(rs.total_refunds,0)
          - COALESCE(rs.total_restocking_cost,0), 0)   AS net_revenue_inr,
    rs.top_return_reason,
    -- Industry benchmark: >15% return rate = problem
    CASE WHEN 100.0 * COALESCE(rs.units_returned,0) /
                     NULLIF(ss.total_units_sold,0) > 15
         THEN 'HIGH RETURN — Review Quality'
         WHEN 100.0 * COALESCE(rs.units_returned,0) /
                      NULLIF(ss.total_units_sold,0) > 8
         THEN 'ELEVATED — Monitor'
         ELSE 'NORMAL'
    END                                                AS return_flag
FROM sales_summary ss
LEFT JOIN return_summary rs ON ss.product_id = rs.product_id
ORDER BY return_rate_pct DESC;


-- ══════════════════════════════════════════════════════════════════
-- QUERY 7: Festive Season vs Non-Festive Performance
-- Quantifies revenue lift from Diwali/festive window
-- ══════════════════════════════════════════════════════════════════

WITH daily_sales AS (
    SELECT
        transaction_date,
        MONTH(transaction_date)                         AS mo,
        SUM(revenue)                                    AS daily_revenue,
        COUNT(DISTINCT transaction_id)                  AS daily_transactions,
        COUNT(DISTINCT customer_id)                     AS daily_customers,
        ROUND(AVG(revenue), 2)                          AS avg_order_value,
        CASE
            WHEN MONTH(transaction_date) IN (10, 11)
                THEN 'Festive (Oct-Nov)'
            WHEN MONTH(transaction_date) IN (12, 1)
                THEN 'Holiday (Dec-Jan)'
            WHEN MONTH(transaction_date) IN (7, 8)
                THEN 'Monsoon (Jul-Aug)'
            ELSE 'Regular'
        END                                             AS season_type
    FROM vw_clean_transactions
    GROUP BY transaction_date, MONTH(transaction_date)
)
SELECT
    season_type,
    COUNT(DISTINCT transaction_date)                    AS days_in_period,
    ROUND(SUM(daily_revenue), 0)                       AS total_revenue_inr,
    ROUND(AVG(daily_revenue), 0)                       AS avg_daily_revenue_inr,
    ROUND(SUM(daily_transactions) * 1.0 /
          COUNT(DISTINCT transaction_date), 0)         AS avg_daily_transactions,
    ROUND(AVG(avg_order_value), 0)                     AS avg_order_value_inr,
    -- Index vs overall average daily revenue
    ROUND(AVG(daily_revenue) /
          (SELECT AVG(daily_revenue) FROM daily_sales) * 100, 1)
                                                        AS revenue_index
FROM daily_sales
GROUP BY season_type
ORDER BY avg_daily_revenue_inr DESC;


-- ══════════════════════════════════════════════════════════════════
-- QUERY 8: Category Sell-Through Decay Cohort
-- How does sell-through slow down week-by-week per category?
-- The core data for markdown trigger recommendations
-- ══════════════════════════════════════════════════════════════════

WITH weekly_cohort AS (
    SELECT
        p.category,
        p.season,
        i.week_number,
        COUNT(DISTINCT i.product_id)                   AS sku_count,
        SUM(i.units_sold)                              AS units_sold,
        SUM(i.opening_stock)                           AS total_opening_stock,
        ROUND(
            CAST(SUM(i.units_sold) AS FLOAT) /
            NULLIF(SUM(i.opening_stock), 0) * 100, 2
        )                                              AS weekly_velocity_pct,
        ROUND(AVG(
            1.0 - CAST(i.closing_stock AS FLOAT) /
            NULLIF(i.opening_stock, 0)
        ) * 100, 2)                                    AS avg_cumulative_st_pct,
        SUM(i.revenue)                                 AS weekly_revenue,
        COUNT(CASE WHEN i.markdown_pct > 0 THEN 1 END) AS skus_marked_down
    FROM fact_inventory i
    JOIN dim_products p ON i.product_id = p.product_id
    WHERE i.week_number <= 16
    GROUP BY p.category, p.season, i.week_number
)
SELECT
    category,
    season,
    week_number,
    sku_count,
    weekly_velocity_pct,
    avg_cumulative_st_pct,
    -- Running cumulative sell-through
    SUM(units_sold) OVER (
        PARTITION BY category, season
        ORDER BY week_number
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                                  AS cumulative_units_sold,
    skus_marked_down,
    weekly_revenue,
    -- Flag if sell-through falling below danger threshold
    CASE
        WHEN avg_cumulative_st_pct < 25 AND week_number >= 6
            THEN 'MARKDOWN TRIGGER — ST below 25% at week 6+'
        WHEN avg_cumulative_st_pct < 40 AND week_number >= 10
            THEN 'MARKDOWN TRIGGER — ST below 40% at week 10+'
        ELSE 'ON TRACK'
    END                                                AS markdown_signal
FROM weekly_cohort
ORDER BY category, season, week_number;


-- ══════════════════════════════════════════════════════════════════
-- QUERY 9: Top Customer Churn Risk — High Value At-Risk Segment
-- Identifies Champions / Loyal customers who are going silent
-- ══════════════════════════════════════════════════════════════════

WITH customer_history AS (
    SELECT
        t.customer_id,
        c.customer_name,
        c.loyalty_tier,
        c.region,
        c.age_group,
        c.preferred_channel,
        COUNT(DISTINCT t.transaction_id)               AS lifetime_orders,
        ROUND(SUM(t.revenue), 2)                       AS lifetime_value_inr,
        ROUND(AVG(t.revenue), 2)                       AS avg_order_value,
        MAX(t.transaction_date)                        AS last_purchase_date,
        MIN(t.transaction_date)                        AS first_purchase_date,
        DATEDIFF(day, MAX(t.transaction_date),'2024-09-30')
                                                        AS days_since_last_purchase,
        -- Purchase gap in last 6 months
        COUNT(CASE WHEN t.transaction_date >= '2024-04-01'
                   THEN 1 END)                         AS orders_last_6m,
        COUNT(CASE WHEN t.transaction_date >= '2023-04-01'
                        AND t.transaction_date < '2024-04-01'
                   THEN 1 END)                         AS orders_prev_6m
    FROM vw_clean_transactions t
    JOIN dim_customers c ON t.customer_id = c.customer_id
    WHERE t.customer_id IS NOT NULL
    GROUP BY t.customer_id, c.customer_name, c.loyalty_tier,
             c.region, c.age_group, c.preferred_channel
),
churn_scored AS (
    SELECT
        *,
        -- Churn risk: high value + going silent
        CASE
            WHEN lifetime_value_inr > 15000
             AND days_since_last_purchase > 90
             AND orders_last_6m < orders_prev_6m * 0.5
                THEN 'HIGH CHURN RISK — Winback Campaign'
            WHEN lifetime_value_inr > 8000
             AND days_since_last_purchase > 60
                THEN 'MEDIUM CHURN RISK — Re-engagement'
            WHEN lifetime_value_inr > 20000
             AND orders_last_6m >= 2
                THEN 'VIP — Retention Priority'
            ELSE 'STANDARD'
        END AS churn_risk_flag,
        ROUND(
            lifetime_value_inr * 0.35 *
            (1.0 / NULLIF(days_since_last_purchase, 0) * 100)
        , 0)                                           AS estimated_winback_value
    FROM customer_history
    WHERE lifetime_value_inr > 5000    -- focus on valuable customers
)
SELECT
    churn_risk_flag,
    COUNT(*)                                           AS customer_count,
    ROUND(AVG(lifetime_value_inr), 0)                 AS avg_ltv_inr,
    ROUND(SUM(lifetime_value_inr), 0)                 AS total_revenue_at_risk_inr,
    ROUND(AVG(days_since_last_purchase), 0)           AS avg_days_inactive,
    ROUND(AVG(avg_order_value), 0)                    AS avg_order_value_inr,
    ROUND(AVG(CAST(orders_last_6m AS FLOAT)), 1)      AS avg_orders_last_6m,
    ROUND(AVG(CAST(orders_prev_6m AS FLOAT)), 1)      AS avg_orders_prev_6m
FROM churn_scored
GROUP BY churn_risk_flag
ORDER BY total_revenue_at_risk_inr DESC;
