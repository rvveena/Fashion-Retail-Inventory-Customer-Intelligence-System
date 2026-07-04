-- ================================================================
-- IndiaStyle Retail — Business Intelligence System
-- Layer 1: Schema Definition
-- Author: Veena V R | Data Analyst Portfolio
-- Database: SQL Server 2019+
-- ================================================================

-- ── DIMENSION TABLES ─────────────────────────────────────────────

CREATE TABLE dim_stores (
    store_id            VARCHAR(10)     PRIMARY KEY,
    store_name          VARCHAR(100)    NOT NULL,
    region              VARCHAR(50)     NOT NULL,
    channel             VARCHAR(30)     NOT NULL,
    store_size_sqft     INT,
    opening_date        DATE,
    store_manager       VARCHAR(100),
    monthly_rent_inr    DECIMAL(12,2),
    contact_email       VARCHAR(100)    -- nullable: some stores missing
);

CREATE TABLE dim_products (
    product_id          VARCHAR(10)     PRIMARY KEY,
    product_name        VARCHAR(150)    NOT NULL,
    category            VARCHAR(50)     NOT NULL,
    sub_category        VARCHAR(80),
    brand               VARCHAR(80)     NOT NULL,
    gender              VARCHAR(20),
    cost_price          DECIMAL(10,2)   NOT NULL,
    mrp                 DECIMAL(10,2)   NOT NULL,
    season              VARCHAR(50),
    launch_date         DATE,
    supplier_code       VARCHAR(20),
    supplier_name       VARCHAR(100),   -- nullable: missing on some
    color               VARCHAR(50),    -- nullable: missing on some
    heat_score          VARCHAR(10)     -- hero/core/slow/dead
);

CREATE TABLE dim_customers (
    customer_id         VARCHAR(12)     PRIMARY KEY,
    customer_name       VARCHAR(100)    NOT NULL,
    email               VARCHAR(100),   -- nullable
    phone               VARCHAR(20),    -- nullable
    city                VARCHAR(80),
    region              VARCHAR(50),
    gender              VARCHAR(20),
    age_group           VARCHAR(20),
    loyalty_tier        VARCHAR(20),
    registration_date   DATE,
    preferred_channel   VARCHAR(30)
);

-- ── FACT TABLES ───────────────────────────────────────────────────

CREATE TABLE fact_inventory (
    inventory_id            VARCHAR(12)     PRIMARY KEY,
    product_id              VARCHAR(10)     NOT NULL REFERENCES dim_products(product_id),
    store_id                VARCHAR(10)     NOT NULL REFERENCES dim_stores(store_id),
    week_number             INT             NOT NULL,
    week_date               DATE            NOT NULL,
    opening_stock           INT             NOT NULL,
    units_sold              INT             NOT NULL DEFAULT 0,
    closing_stock           INT             NOT NULL,
    closing_stock_reported  INT,            -- may be negative (system error)
    days_on_shelf           INT             NOT NULL DEFAULT 0,
    markdown_pct            DECIMAL(5,2)    NOT NULL DEFAULT 0,
    effective_price         DECIMAL(10,2),
    gross_margin_pct        DECIMAL(5,2),
    revenue                 DECIMAL(12,2)   NOT NULL DEFAULT 0
);

CREATE TABLE fact_transactions (
    transaction_id      VARCHAR(10)     PRIMARY KEY,
    transaction_date    DATE            NOT NULL,
    customer_id         VARCHAR(12),    -- nullable: guest checkouts
    product_id          VARCHAR(10)     NOT NULL REFERENCES dim_products(product_id),
    store_id            VARCHAR(10)     NOT NULL REFERENCES dim_stores(store_id),
    quantity            INT             NOT NULL DEFAULT 1,
    unit_price          DECIMAL(10,2)   NOT NULL,
    discount_pct        DECIMAL(5,2)    NOT NULL DEFAULT 0,
    revenue             DECIMAL(12,2)   NOT NULL,
    cost                DECIMAL(12,2)   NOT NULL,
    payment_method      VARCHAR(30),    -- nullable: system gaps
    channel             VARCHAR(30),
    region              VARCHAR(50)
);

CREATE TABLE fact_returns (
    return_id           VARCHAR(10)     PRIMARY KEY,
    transaction_id      VARCHAR(10)     NOT NULL,
    product_id          VARCHAR(10)     NOT NULL REFERENCES dim_products(product_id),
    customer_id         VARCHAR(12),
    store_id            VARCHAR(10)     REFERENCES dim_stores(store_id),
    return_date         DATE            NOT NULL,
    return_reason       VARCHAR(80),
    quantity_returned   INT             NOT NULL DEFAULT 1,
    refund_amount       DECIMAL(12,2),
    restocking_cost     DECIMAL(10,2),
    resaleable          BIT             DEFAULT 1
);

CREATE TABLE fact_markdown_events (
    markdown_id         VARCHAR(10)     PRIMARY KEY,
    product_id          VARCHAR(10)     NOT NULL REFERENCES dim_products(product_id),
    store_id            VARCHAR(10)     REFERENCES dim_stores(store_id),
    markdown_date       DATE            NOT NULL,
    markdown_week       INT,
    markdown_pct        DECIMAL(5,2)    NOT NULL,
    days_on_shelf_at_md INT,
    stock_at_markdown   INT,
    sell_through_at_md  DECIMAL(5,4),
    approved_by         VARCHAR(50),
    markdown_type       VARCHAR(30)
);

CREATE TABLE fact_sales_targets (
    target_id           VARCHAR(10)     PRIMARY KEY,
    store_id            VARCHAR(10)     NOT NULL REFERENCES dim_stores(store_id),
    month               VARCHAR(7)      NOT NULL,
    category            VARCHAR(50),
    target_revenue      DECIMAL(14,2)   NOT NULL,
    actual_revenue      DECIMAL(14,2)   NOT NULL,
    target_units        INT,
    actual_units        INT,
    attainment_pct      DECIMAL(6,2)
);

-- ── INDEXES ───────────────────────────────────────────────────────
CREATE INDEX idx_txn_date        ON fact_transactions (transaction_date);
CREATE INDEX idx_txn_product     ON fact_transactions (product_id);
CREATE INDEX idx_txn_customer    ON fact_transactions (customer_id);
CREATE INDEX idx_txn_store       ON fact_transactions (store_id);
CREATE INDEX idx_inv_product     ON fact_inventory    (product_id);
CREATE INDEX idx_inv_store       ON fact_inventory    (store_id);
CREATE INDEX idx_inv_week        ON fact_inventory    (week_number);
CREATE INDEX idx_ret_txn         ON fact_returns      (transaction_id);
CREATE INDEX idx_ret_product     ON fact_returns      (product_id);
CREATE INDEX idx_tgt_store_month ON fact_sales_targets(store_id, month);
