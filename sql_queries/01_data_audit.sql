"""
India Retail — Synthetic Data Generator
8 relational tables, deliberately messy (nulls, duplicates, anomalies)
Mimics a mid-size Indian fashion retailer (Zara/Westside-style operations)
"""
import pandas as pd
import numpy as np
from faker import Faker
from datetime import datetime, timedelta
import random, os, warnings
warnings.filterwarnings("ignore")

fake = Faker('en_IN')
np.random.seed(42)
random.seed(42)

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data")
os.makedirs(OUT, exist_ok=True)

# ── CONSTANTS ──────────────────────────────────────────────────────────────────
REGIONS   = ["North India","South India","West India","East India",
             "Metro Mumbai","Metro Delhi","Metro Bengaluru"]
CHANNELS  = ["In-Store","Online","Omnichannel"]
CATEGORIES= ["Tops","Bottoms","Dresses","Outerwear","Footwear","Accessories","Ethnic Wear"]
SEASONS   = ["Festive 2023","Winter 2023","Summer 2024","Monsoon 2024"]
GENDERS   = ["Men","Women","Unisex","Kids"]
BRANDS    = ["IndiaStyle Core","IndiaStyle Premium","IndiaStyle Sport",
             "IndiaStyle Ethnic","IndiaStyle Kids"]
STORES    = [f"ST-{i:03d}" for i in range(1, 36)]
STORE_REGIONS = {s: REGIONS[i % len(REGIONS)] for i, s in enumerate(STORES)}

START_DATE = datetime(2023, 4, 1)
END_DATE   = datetime(2024, 9, 30)
N_CUSTOMERS = 5000
N_PRODUCTS  = 600
N_TRANSACTIONS = 55000

# ── TABLE 1: dim_stores ────────────────────────────────────────────────────────
print("Generating dim_stores...")
stores = []
for s in STORES:
    region = STORE_REGIONS[s]
    stores.append({
        "store_id":      s,
        "store_name":    f"IndiaStyle {fake.city()}",
        "region":        region,
        "channel":       np.random.choice(CHANNELS, p=[0.50,0.30,0.20]),
        "store_size_sqft": int(np.random.uniform(1200, 8000)),
        "opening_date":  fake.date_between(start_date="-5y", end_date="-1y"),
        "store_manager": fake.name(),
        "monthly_rent_inr": int(np.random.uniform(80000, 600000)),
        # Inject nulls — some stores missing manager info
        "contact_email": fake.email() if random.random() > 0.08 else None,
    })
dim_stores = pd.DataFrame(stores)

# ── TABLE 2: dim_products ──────────────────────────────────────────────────────
print("Generating dim_products...")
products = []
for i in range(N_PRODUCTS):
    cat    = np.random.choice(CATEGORIES, p=[0.22,0.18,0.16,0.10,0.12,0.10,0.12])
    gender = np.random.choice(GENDERS,    p=[0.30,0.40,0.15,0.15])
    brand  = np.random.choice(BRANDS)
    cost   = round(np.random.uniform(150, 2800), 2)
    mrp    = round(cost * np.random.uniform(2.1, 4.2), 2)
    heat   = np.random.choice(["hero","core","slow","dead"],
                               p=[0.15, 0.45, 0.28, 0.12])
    products.append({
        "product_id":    f"PRD-{i+1:04d}",
        "product_name":  f"{brand} {cat} {fake.color_name()} {i+1:04d}",
        "category":      cat,
        "sub_category":  f"{gender} {cat}",
        "brand":         brand,
        "gender":        gender,
        "cost_price":    cost,
        "mrp":           mrp,
        "season":        np.random.choice(SEASONS),
        "launch_date":   fake.date_between(start_date=START_DATE,
                                           end_date=END_DATE - timedelta(days=30)),
        "supplier_code": f"SUP-{random.randint(1,40):03d}",
        "heat_score":    heat,
        # Inject nulls — supplier missing on some products
        "supplier_name": fake.company() if random.random() > 0.12 else None,
        "color":         fake.color_name() if random.random() > 0.05 else None,
    })
dim_products = pd.DataFrame(products)

# ── TABLE 3: dim_customers ─────────────────────────────────────────────────────
print("Generating dim_customers...")
customers = []
for i in range(N_CUSTOMERS):
    reg = np.random.choice(REGIONS, p=[0.15,0.18,0.20,0.10,0.14,0.12,0.11])
    customers.append({
        "customer_id":     f"CUS-{i+1:05d}",
        "customer_name":   fake.name(),
        "email":           fake.email() if random.random() > 0.06 else None,
        "phone":           fake.phone_number() if random.random() > 0.04 else None,
        "city":            fake.city(),
        "region":          reg,
        "gender":          np.random.choice(["Male","Female","Other"],
                                            p=[0.42,0.55,0.03]),
        "age_group":       np.random.choice(["18-24","25-34","35-44","45-54","55+"],
                                            p=[0.22,0.35,0.25,0.12,0.06]),
        "loyalty_tier":    np.random.choice(["Bronze","Silver","Gold","Platinum"],
                                            p=[0.45,0.30,0.17,0.08]),
        "registration_date": fake.date_between(start_date="-4y", end_date="-3m"),
        "preferred_channel": np.random.choice(CHANNELS, p=[0.45,0.38,0.17]),
    })
dim_customers = pd.DataFrame(customers)

# ── TABLE 4: fact_inventory ────────────────────────────────────────────────────
print("Generating fact_inventory (this takes a moment)...")
vel_map = {"hero":0.16,"core":0.09,"slow":0.04,"dead":0.012}
inv_rows = []
# Sample 200 products × 35 stores for weekly snapshot
sampled_prods = dim_products.sample(200, random_state=42)
for _, p in sampled_prods.iterrows():
    for store_id in STORES[:20]:  # 20 stores
        stock = int(np.random.uniform(40, 250))
        md_pct = 0.0
        base_vel = vel_map[p["heat_score"]]
        launch   = pd.to_datetime(p["launch_date"])
        for week in range(1, 27):
            w_date     = START_DATE + timedelta(weeks=week-1)
            if pd.Timestamp(w_date) < launch:
                continue
            weeks_live = (pd.Timestamp(w_date) - launch).days // 7
            decay      = np.exp(-0.055 * weeks_live)
            md_lift    = 1 + 1.8 * md_pct
            sold       = int(stock * base_vel * decay * md_lift * np.random.uniform(0.78,1.22))
            sold       = min(sold, stock)
            st_rate    = 1 - stock / p.get("initial_stock", 150)
            if md_pct == 0 and weeks_live >= 9 and (1 - stock/150) < 0.35:
                md_pct = round(np.random.uniform(0.20, 0.45), 2)
            eff_price  = round(float(p["mrp"]) * (1 - md_pct), 2)
            gm         = round((eff_price - float(p["cost_price"])) / eff_price * 100, 2) \
                         if eff_price > 0 else 0
            inv_rows.append({
                "inventory_id":   f"INV-{len(inv_rows)+1:07d}",
                "product_id":     p["product_id"],
                "store_id":       store_id,
                "week_number":    week,
                "week_date":      w_date.strftime("%Y-%m-%d"),
                "opening_stock":  stock,
                "units_sold":     sold,
                "closing_stock":  stock - sold,
                "days_on_shelf":  weeks_live * 7,
                "markdown_pct":   md_pct,
                "effective_price":eff_price,
                "gross_margin_pct": gm,
                "revenue":        round(sold * eff_price, 2),
                # Inject anomalies
                "closing_stock_reported": (stock - sold) if random.random() > 0.03
                                          else -(stock - sold),  # negative stock error
            })
            stock -= sold
            if stock <= 0:
                break
fact_inventory = pd.DataFrame(inv_rows)

# ── TABLE 5: fact_transactions ─────────────────────────────────────────────────
print("Generating fact_transactions...")
txn_rows = []
product_ids  = dim_products["product_id"].tolist()
customer_ids = dim_customers["customer_id"].tolist()

# Festive season spike (Oct-Nov)
def get_daily_weight(date):
    m = date.month
    if m in [10, 11]: return 3.2   # Diwali / festive
    if m in [12, 1]:  return 1.8   # winter/new year
    if m in [7, 8]:   return 0.7   # monsoon slow
    return 1.0

date_range = [START_DATE + timedelta(days=d)
              for d in range((END_DATE - START_DATE).days)]
weights    = [get_daily_weight(d) for d in date_range]
weights    = np.array(weights) / sum(weights)
txn_dates  = np.random.choice(date_range, size=N_TRANSACTIONS, p=weights)

payment_methods = ["UPI","Credit Card","Debit Card","COD","Net Banking","Wallet"]
payment_weights = [0.38,0.22,0.18,0.12,0.06,0.04]

for i, txn_date in enumerate(txn_dates):
    prod    = dim_products.iloc[random.randint(0, N_PRODUCTS-1)]
    cust_id = random.choice(customer_ids)
    store   = random.choice(STORES)
    qty     = int(np.random.choice([1,2,3,4], p=[0.65,0.22,0.09,0.04]))
    disc    = round(np.random.uniform(0, 0.35), 2)
    unit_price = round(float(prod["mrp"]) * (1 - disc), 2)
    revenue    = round(unit_price * qty, 2)
    txn_rows.append({
        "transaction_id":  f"TXN-{i+1:06d}",
        "transaction_date":txn_date.strftime("%Y-%m-%d"),
        "customer_id":     cust_id,
        "product_id":      prod["product_id"],
        "store_id":        store,
        "quantity":        qty,
        "unit_price":      unit_price,
        "discount_pct":    disc,
        "revenue":         revenue,
        "cost":            round(float(prod["cost_price"]) * qty, 2),
        "payment_method":  np.random.choice(payment_methods, p=payment_weights),
        "channel":         np.random.choice(CHANNELS, p=[0.48,0.35,0.17]),
        "region":          STORE_REGIONS[store],
        # Inject nulls
        "customer_id":     cust_id if random.random() > 0.07 else None,
        "payment_method":  np.random.choice(payment_methods, p=payment_weights)
                           if random.random() > 0.04 else None,
    })

# Inject duplicate transactions (~1.5%)
dupes = random.sample(txn_rows, int(N_TRANSACTIONS * 0.015))
txn_rows.extend(dupes)
fact_transactions = pd.DataFrame(txn_rows)

# ── TABLE 6: fact_returns ──────────────────────────────────────────────────────
print("Generating fact_returns...")
eligible = fact_transactions.dropna(subset=["customer_id"]).sample(
    int(N_TRANSACTIONS * 0.11), random_state=42)
return_reasons = ["Size issue","Quality defect","Wrong item","Changed mind",
                  "Damaged in transit","Colour mismatch","Late delivery"]
ret_rows = []
for _, t in eligible.iterrows():
    days_to_return = int(np.random.exponential(8))
    ret_rows.append({
        "return_id":       f"RET-{len(ret_rows)+1:05d}",
        "transaction_id":  t["transaction_id"],
        "product_id":      t["product_id"],
        "customer_id":     t["customer_id"],
        "store_id":        t["store_id"],
        "return_date":     (pd.to_datetime(t["transaction_date"]) +
                            timedelta(days=days_to_return)).strftime("%Y-%m-%d"),
        "return_reason":   np.random.choice(return_reasons,
                           p=[0.28,0.18,0.15,0.14,0.12,0.08,0.05]),
        "quantity_returned": t["quantity"],
        "refund_amount":   round(t["revenue"] * np.random.uniform(0.85, 1.0), 2),
        "restocking_cost": round(t["revenue"] * 0.08, 2),
        "resaleable":      np.random.choice([True, False], p=[0.72, 0.28]),
    })
fact_returns = pd.DataFrame(ret_rows)

# ── TABLE 7: fact_markdown_events ──────────────────────────────────────────────
print("Generating fact_markdown_events...")
md_rows = []
md_inventory = fact_inventory[fact_inventory["markdown_pct"] > 0]
for _, row in md_inventory.drop_duplicates("product_id").iterrows():
    prod = dim_products[dim_products["product_id"] == row["product_id"]].iloc[0]
    md_rows.append({
        "markdown_id":         f"MD-{len(md_rows)+1:05d}",
        "product_id":          row["product_id"],
        "store_id":            row["store_id"],
        "markdown_date":       row["week_date"],
        "markdown_week":       row["week_number"],
        "markdown_pct":        row["markdown_pct"],
        "days_on_shelf_at_md": row["days_on_shelf"],
        "stock_at_markdown":   row["opening_stock"],
        "sell_through_at_md":  round(1 - row["opening_stock"] / 150, 4),
        "approved_by":         np.random.choice(["Regional Manager","Category Head",
                                                  "Auto-trigger","Store Manager"]),
        "markdown_type":       np.random.choice(["Seasonal","Clearance",
                                                  "Slow-mover","Promotional"],
                                                  p=[0.35,0.30,0.25,0.10]),
    })
fact_markdown = pd.DataFrame(md_rows)

# ── TABLE 8: fact_sales_targets ───────────────────────────────────────────────
print("Generating fact_sales_targets...")
target_rows = []
months = pd.date_range(START_DATE, END_DATE, freq="MS")
for store in STORES:
    for month in months:
        base = np.random.uniform(800000, 4500000)
        # Metro stores have higher targets
        if STORE_REGIONS[store] in ["Metro Mumbai","Metro Delhi","Metro Bengaluru"]:
            base *= 1.6
        # Festive bump
        if month.month in [10, 11]:
            base *= 1.85
        actual = base * np.random.uniform(0.72, 1.18)
        target_rows.append({
            "target_id":     f"TGT-{len(target_rows)+1:05d}",
            "store_id":      store,
            "month":         month.strftime("%Y-%m"),
            "target_revenue":round(base, 2),
            "actual_revenue":round(actual, 2),
            "target_units":  int(base / 900),
            "actual_units":  int(actual / 900 * np.random.uniform(0.88, 1.12)),
            "category":      np.random.choice(CATEGORIES),
            "attainment_pct":round(actual / base * 100, 2),
        })
fact_targets = pd.DataFrame(target_rows)

# ── SAVE ALL TABLES ────────────────────────────────────────────────────────────
print("\nSaving all tables...")
tables = {
    "dim_stores":           dim_stores,
    "dim_products":         dim_products,
    "dim_customers":        dim_customers,
    "fact_inventory":       fact_inventory,
    "fact_transactions":    fact_transactions,
    "fact_returns":         fact_returns,
    "fact_markdown_events": fact_markdown,
    "fact_sales_targets":   fact_targets,
}
for name, df in tables.items():
    path = f"{OUT}/{name}.csv"
    df.to_csv(path, index=False)
    print(f"  ✓ {name:<25} {len(df):>7,} rows  →  {path.split('/')[-1]}")

print(f"\n{'='*55}")
print(f"DATASET SUMMARY")
print(f"{'='*55}")
print(f"Customers:        {len(dim_customers):>7,}")
print(f"Products:         {len(dim_products):>7,}")
print(f"Stores:           {len(dim_stores):>7,}")
print(f"Transactions:     {len(fact_transactions):>7,}")
print(f"Returns:          {len(fact_returns):>7,}")
print(f"Inventory rows:   {len(fact_inventory):>7,}")
print(f"Markdown events:  {len(fact_markdown):>7,}")
print(f"Sales targets:    {len(fact_targets):>7,}")
total = sum(len(df) for df in tables.values())
print(f"{'─'*35}")
print(f"TOTAL ROWS:       {total:>7,}")
print(f"\nDeliberate data quality issues injected:")
print(f"  • Negative closing stock (inventory errors)")
print(f"  • ~7% null customer_id in transactions")
print(f"  • ~4% null payment_method")
print(f"  • ~1.5% duplicate transactions")
print(f"  • ~8% null contact_email in stores")
print(f"  • ~12% null supplier_name in products")
print(f"  • ~5% null color field in products")
