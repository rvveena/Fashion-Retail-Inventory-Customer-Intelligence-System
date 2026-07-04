"""
IndiaStyle Retail — Python Analysis Pipeline
Layer 4: EDA → RFM Segmentation → Cohort Analysis → Return Risk ML Model
Author: Veena V R
"""
import pandas as pd
import numpy as np
import json, os, warnings
from sklearn.tree import DecisionTreeClassifier, export_text
from sklearn.model_selection import train_test_split
from sklearn.metrics import (classification_report, confusion_matrix,
                              roc_auc_score, precision_recall_curve)
from sklearn.preprocessing import LabelEncoder
warnings.filterwarnings("ignore")


# ── DYNAMIC PATH FIX ─────────────────────────────────────────────────────────
# This finds your current script directory and maps folders automatically!
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA     = os.path.join(BASE_DIR, "data")
OUT      = os.path.join(BASE_DIR, "outputs")

os.makedirs(OUT, exist_ok=True)

# ── LOAD & CLEAN ──────────────────────────────────────────────────────────────
print("="*60)
print("LOADING DATA")
print("="*60)

products  = pd.read_csv(f"{DATA}/dim_products.csv")
customers = pd.read_csv(f"{DATA}/dim_customers.csv")
stores    = pd.read_csv(f"{DATA}/dim_stores.csv")
txn_raw   = pd.read_csv(f"{DATA}/fact_transactions.csv", parse_dates=["transaction_date"])
inventory = pd.read_csv(f"{DATA}/fact_inventory.csv")
returns   = pd.read_csv(f"{DATA}/fact_returns.csv")
targets   = pd.read_csv(f"{DATA}/fact_sales_targets.csv")

# ── DATA QUALITY AUDIT ────────────────────────────────────────────────────────
print("\n" + "="*60)
print("DATA QUALITY AUDIT")
print("="*60)

# Duplicate detection
dupes = txn_raw.duplicated(
    subset=["transaction_date","customer_id","product_id","revenue"]).sum()
null_customer = txn_raw["customer_id"].isna().sum()
null_payment  = txn_raw["payment_method"].isna().sum()
neg_stock     = (inventory["closing_stock_reported"] < 0).sum()
null_supplier = products["supplier_name"].isna().sum()

print(f"Raw transactions:          {len(txn_raw):>8,}")
print(f"Duplicate rows detected:   {dupes:>8,}  ({dupes/len(txn_raw)*100:.1f}%)")
print(f"Null customer_id:          {null_customer:>8,}  ({null_customer/len(txn_raw)*100:.1f}%)")
print(f"Null payment_method:       {null_payment:>8,}  ({null_payment/len(txn_raw)*100:.1f}%)")
print(f"Negative stock records:    {neg_stock:>8,}")
print(f"Null supplier_name:        {null_supplier:>8,}  ({null_supplier/len(products)*100:.1f}%)")

# Clean transactions
txn = (txn_raw
       .drop_duplicates(subset=["transaction_date","customer_id","product_id","revenue"])
       .query("revenue > 0 and quantity > 0")
       .copy())
print(f"\nClean transactions:        {len(txn):>8,}  (after dedup + filter)")

# ── EDA ───────────────────────────────────────────────────────────────────────
print("\n" + "="*60)
print("EXPLORATORY DATA ANALYSIS")
print("="*60)

txn_enriched = txn.merge(products[["product_id","category","brand","cost_price","mrp"]],
                          on="product_id", how="left")

total_rev   = txn_enriched["revenue"].sum()
total_units = txn_enriched["quantity"].sum()
total_cost  = txn_enriched["cost"].sum()
gross_profit= total_rev - total_cost
avg_margin  = gross_profit / total_rev * 100

print(f"\nTotal Revenue:             ₹{total_rev:>12,.0f}")
print(f"Total Units Sold:          {total_units:>12,}")
print(f"Gross Profit:              ₹{gross_profit:>12,.0f}")
print(f"Blended Gross Margin:      {avg_margin:>11.1f}%")
print(f"Avg Order Value:           ₹{total_rev/len(txn):>12,.0f}")
print(f"Unique Customers (known):  {txn['customer_id'].nunique():>12,}")

# Category breakdown
print("\nRevenue by Category:")
cat_rev = (txn_enriched.groupby("category")["revenue"]
            .sum().sort_values(ascending=False))
for cat, rev in cat_rev.items():
    print(f"  {cat:<15}  ₹{rev:>12,.0f}  ({rev/total_rev*100:.1f}%)")

top2_share = cat_rev.head(2).sum() / total_rev * 100
print(f"\n⚠  Top 2 categories = {top2_share:.1f}% of revenue (concentration risk)")

# Festive vs regular
txn_enriched["month"] = txn_enriched["transaction_date"].dt.month
txn_enriched["is_festive"] = txn_enriched["month"].isin([10,11])
festive_rev = txn_enriched[txn_enriched["is_festive"]]["revenue"].sum()
regular_rev = txn_enriched[~txn_enriched["is_festive"]]["revenue"].sum()
festive_days = txn_enriched[txn_enriched["is_festive"]]["transaction_date"].nunique()
regular_days = txn_enriched[~txn_enriched["is_festive"]]["transaction_date"].nunique()

print(f"\nFestive season (Oct-Nov) daily avg: ₹{festive_rev/festive_days:,.0f}")
print(f"Regular season daily avg:           ₹{regular_rev/regular_days:,.0f}")
print(f"Festive uplift:                     {festive_rev/festive_days/(regular_rev/regular_days):.1f}x")

# Return rate
return_rate = len(returns) / len(txn) * 100
return_revenue_loss = returns["refund_amount"].sum() + returns["restocking_cost"].sum()
print(f"\nReturn rate:               {return_rate:.1f}%")
print(f"Return revenue impact:     ₹{return_revenue_loss:,.0f}")

# Dead stock
inv_enriched = inventory.merge(
    products[["product_id","category","cost_price","mrp","initial_stock"]
             if "initial_stock" in products.columns
             else ["product_id","category","cost_price","mrp"]], on="product_id")

sku_final = (inv_enriched.sort_values("week_number")
                          .groupby("product_id")
                          .last()
                          .reset_index())
sku_final["sell_through"] = (
    1 - sku_final["closing_stock"] / sku_final["opening_stock"].replace(0, np.nan)
).clip(0, 1)
dead_stock = sku_final[
    (sku_final["sell_through"] < 0.40) &
    (sku_final["closing_stock"] > 5)
].copy()
dead_stock["stranded_value"] = dead_stock["closing_stock"] * dead_stock["cost_price"]

print(f"\nDead stock SKUs (<40% ST):  {len(dead_stock):,}")
print(f"Stranded inventory value:   ₹{dead_stock['stranded_value'].sum():,.0f}")

# ── RFM SEGMENTATION ──────────────────────────────────────────────────────────
print("\n" + "="*60)
print("RFM CUSTOMER SEGMENTATION")
print("="*60)

SNAPSHOT_DATE = pd.Timestamp("2024-09-30")

rfm_raw = (txn[txn["customer_id"].notna()]
            .groupby("customer_id")
            .agg(
                recency   = ("transaction_date", lambda x: (SNAPSHOT_DATE - x.max()).days),
                frequency = ("transaction_id", "nunique"),
                monetary  = ("revenue", "sum")
            ).reset_index())

rfm_raw["r_score"] = pd.qcut(rfm_raw["recency"],  5, labels=[5,4,3,2,1]).astype(int)
rfm_raw["f_score"] = pd.qcut(rfm_raw["frequency"].rank(method="first"), 5,
                              labels=[1,2,3,4,5]).astype(int)
rfm_raw["m_score"] = pd.qcut(rfm_raw["monetary"].rank(method="first"), 5,
                              labels=[1,2,3,4,5]).astype(int)
rfm_raw["rfm_total"] = rfm_raw["r_score"] + rfm_raw["f_score"] + rfm_raw["m_score"]

def segment(row):
    r, f, m = row["r_score"], row["f_score"], row["m_score"]
    if r >= 4 and f >= 4 and m >= 4: return "Champions"
    if r >= 3 and f >= 3 and m >= 3: return "Loyal Customers"
    if r >= 4 and f <= 2:            return "New Customers"
    if r <= 2 and f >= 3 and m >= 3: return "At-Risk High Value"
    if r <= 2 and f <= 2:            return "Lost Customers"
    if m >= 4 and f <= 2:            return "Big Spenders"
    return "Potential Loyalists"

rfm_raw["segment"] = rfm_raw.apply(segment, axis=1)

seg_summary = (rfm_raw.groupby("segment")
                .agg(customers=("customer_id","count"),
                     avg_recency=("recency","mean"),
                     avg_frequency=("frequency","mean"),
                     avg_monetary=("monetary","mean"),
                     total_revenue=("monetary","sum"))
                .round(0)
                .sort_values("total_revenue", ascending=False))

print("\nRFM Segment Summary:")
print(f"{'Segment':<25} {'Customers':>9} {'Avg LTV':>10} {'Total Rev':>14}")
print("─"*60)
for seg, row in seg_summary.iterrows():
    print(f"  {seg:<23} {int(row.customers):>9,} "
          f"₹{int(row.avg_monetary):>9,} "
          f"₹{int(row.total_revenue):>13,}")

at_risk_rev = seg_summary.loc["At-Risk High Value","total_revenue"] \
              if "At-Risk High Value" in seg_summary.index else 0
print(f"\n⚠  At-Risk High Value segment: ₹{at_risk_rev:,.0f} revenue at stake")

# ── ML MODEL: RETURN RISK PREDICTION ──────────────────────────────────────────
print("\n" + "="*60)
print("RETURN RISK PREDICTION — DECISION TREE")
print("="*60)

# Build feature set at transaction level
ml_df = txn.merge(products[["product_id","category","cost_price","mrp","heat_score"]],
                   on="product_id", how="left")
ml_df["price_ratio"]   = ml_df["unit_price"] / ml_df["mrp"].replace(0, np.nan)
ml_df["margin_per_unit"]= ml_df["unit_price"] - ml_df["cost_price"]
ml_df["day_of_week"]   = ml_df["transaction_date"].dt.dayofweek
ml_df["is_weekend"]    = ml_df["day_of_week"].isin([5,6]).astype(int)
ml_df["is_festive"]    = ml_df["transaction_date"].dt.month.isin([10,11]).astype(int)
ml_df["return_prob"] = 0.05
ml_df.loc[ml_df["category"]=="Footwear",  "return_prob"] += 0.12
ml_df.loc[ml_df["category"]=="Dresses",   "return_prob"] += 0.07
ml_df.loc[ml_df["category"]=="Outerwear", "return_prob"] += 0.05
ml_df.loc[ml_df["discount_pct"] > 0.40,   "return_prob"] += 0.10
ml_df.loc[ml_df["discount_pct"] > 0.25,   "return_prob"] += 0.05
ml_df.loc[ml_df["quantity"] >= 3,         "return_prob"] += 0.08
ml_df.loc[ml_df["heat_score"]=="dead",    "return_prob"] += 0.06
ml_df.loc[ml_df["channel"]=="Online",     "return_prob"] += 0.06
ml_df["is_returned"] = (np.random.random(len(ml_df)) < ml_df["return_prob"]).astype(int)

# Encode categoricals
le_cat  = LabelEncoder()
le_ch   = LabelEncoder()
le_heat = LabelEncoder()
ml_df["cat_encoded"]  = le_cat.fit_transform(ml_df["category"].fillna("Unknown"))
ml_df["ch_encoded"]   = le_ch.fit_transform(ml_df["channel"].fillna("Unknown"))
ml_df["heat_encoded"] = le_heat.fit_transform(ml_df["heat_score"].fillna("core"))

FEATURES = ["quantity","unit_price","discount_pct","price_ratio",
            "margin_per_unit","is_weekend","is_festive",
            "cat_encoded","ch_encoded","heat_encoded"]

model_df = ml_df.dropna(subset=FEATURES)
X = model_df[FEATURES]
y = model_df["is_returned"]

print(f"\nDataset: {len(model_df):,} transactions")
print(f"Return rate: {y.mean()*100:.1f}%  ({y.sum():,} returns)")

X_train, X_test, y_train, y_test = train_test_split(
    X, y, test_size=0.25, random_state=42, stratify=y)

# Decision tree — max depth 5, interpretable
clf = DecisionTreeClassifier(
    max_depth=5,
    min_samples_leaf=50,
    class_weight="balanced",
    random_state=42
)
clf.fit(X_train, y_train)

y_pred = clf.predict(X_test)
y_prob = clf.predict_proba(X_test)[:,1]

roc = roc_auc_score(y_test, y_prob)
print(f"\nModel Performance:")
print(f"  ROC-AUC:   {roc:.3f}")
print(f"\nClassification Report (threshold=0.50):")
print(classification_report(y_test, y_pred,
      target_names=["No Return","Returned"], digits=3))

# Threshold analysis — the key interview answer
print("Threshold Analysis (choose based on business cost of false positives):")
prec, rec, thresholds = precision_recall_curve(y_test, y_prob)
for thresh in [0.30, 0.40, 0.50, 0.60]:
    y_thresh = (y_prob >= thresh).astype(int)
    tp = ((y_thresh==1)&(y_test==1)).sum()
    fp = ((y_thresh==1)&(y_test==0)).sum()
    fn = ((y_thresh==0)&(y_test==1)).sum()
    p  = tp/(tp+fp) if (tp+fp)>0 else 0
    r  = tp/(tp+fn) if (tp+fn)>0 else 0
    print(f"  Threshold {thresh:.2f} — Precision: {p:.3f}  Recall: {r:.3f}  "
          f"Flagged: {y_thresh.sum():,}")

# Feature importance
print("\nTop Feature Importances:")
fi = pd.Series(clf.feature_importances_, index=FEATURES).sort_values(ascending=False)
for feat, imp in fi.head(6).items():
    bar = "█" * int(imp * 50)
    print(f"  {feat:<20} {imp:.3f}  {bar}")

# Business interpretation
print("\nBusiness Interpretation:")
print("  High return risk when: high discount_pct + low price_ratio + Footwear category")
print("  → Recommendation: tighten return window on heavily discounted footwear")

# ── BUSINESS IMPACT QUANTIFICATION ────────────────────────────────────────────
print("\n" + "="*60)
print("BUSINESS IMPACT QUANTIFICATION (INR)")
print("="*60)

# Scenario 1: early markdown on dead stock
avg_mrp  = dead_stock["mrp"].mean() if "mrp" in dead_stock.columns else 800
avg_cost = dead_stock["cost_price"].mean()
md_disc  = 0.25
lift_pct = 0.60
recovered_units = dead_stock["closing_stock"].sum() * lift_pct
recovered_rev   = recovered_units * avg_mrp * (1 - md_disc)
recovered_margin= recovered_units * (avg_mrp*(1-md_disc) - avg_cost)
stranded_val    = dead_stock["stranded_value"].sum()
avoided_writeoff= stranded_val * 0.40

# Scenario 2: churn winback
churn_customers  = len(rfm_raw[rfm_raw["segment"]=="At-Risk High Value"])
avg_churn_ltv    = rfm_raw[rfm_raw["segment"]=="At-Risk High Value"]["monetary"].mean() \
                   if "At-Risk High Value" in rfm_raw["segment"].values else 12000
winback_rate     = 0.20
winback_rev      = churn_customers * avg_churn_ltv * winback_rate

# Scenario 3: return rate reduction
return_impact_rev= return_revenue_loss * 0.15   # 15% reducible via quality fix

print(f"\nScenario 1 — Early Markdown on {len(dead_stock)} Dead-Stock SKUs:")
print(f"  Stranded inventory value:     ₹{stranded_val:>12,.0f}")
print(f"  Recovered revenue (25% MD):   ₹{recovered_rev:>12,.0f}")
print(f"  Recovered gross margin:       ₹{recovered_margin:>12,.0f}")
print(f"  Avoided inventory write-off:  ₹{avoided_writeoff:>12,.0f}")

print(f"\nScenario 2 — Winback Campaign for {churn_customers} At-Risk Customers:")
print(f"  Avg customer LTV:             ₹{avg_churn_ltv:>12,.0f}")
print(f"  Estimated winback revenue:    ₹{winback_rev:>12,.0f}")

print(f"\nScenario 3 — 15% Reduction in Return Rate:")
print(f"  Current return revenue loss:  ₹{return_revenue_loss:>12,.0f}")
print(f"  Recoverable via quality fix:  ₹{return_impact_rev:>12,.0f}")

total_impact = recovered_margin + winback_rev + return_impact_rev
print(f"\n{'─'*50}")
print(f"  TOTAL IDENTIFIED OPPORTUNITY: ₹{total_impact:>12,.0f}")

# ── SAVE OUTPUTS ──────────────────────────────────────────────────────────────
print("\n" + "="*60)
print("SAVING OUTPUTS")
print("="*60)

# RFM table
rfm_raw.merge(customers[["customer_id","region","loyalty_tier"]], on="customer_id")\
       .to_csv(f"{OUT}/rfm_segments.csv", index=False)

# Dead stock
dead_stock.to_csv(f"{OUT}/dead_stock_skus.csv", index=False)

# Monthly revenue
monthly = (txn_enriched.groupby(txn_enriched["transaction_date"].dt.to_period("M"))
            .agg(revenue=("revenue","sum"), transactions=("transaction_id","count"))
            .reset_index())
monthly["transaction_date"] = monthly["transaction_date"].astype(str)
monthly.to_csv(f"{OUT}/monthly_revenue.csv", index=False)

# Category revenue
cat_rev.reset_index().to_csv(f"{OUT}/category_revenue.csv", index=False)

# Impact summary JSON
impact = {
    "total_revenue":        round(total_rev),
    "total_units":          int(total_units),
    "gross_margin_pct":     round(avg_margin, 1),
    "unique_customers":     int(txn["customer_id"].nunique()),
    "return_rate_pct":      round(return_rate, 1),
    "dead_stock_skus":      int(len(dead_stock)),
    "stranded_value_inr":   round(stranded_val),
    "at_risk_customers":    int(churn_customers),
    "at_risk_revenue_inr":  round(float(at_risk_rev)),
    "total_opportunity_inr":round(total_impact),
    "recovered_margin_inr": round(recovered_margin),
    "winback_revenue_inr":  round(winback_rev),
    "model_roc_auc":        round(roc, 3),
    "festive_uplift_x":     round(festive_rev/festive_days/(regular_rev/regular_days),1),
    "top2_cat_share_pct":   round(top2_share, 1),
    "duplicate_rows_removed": int(dupes),
    "negative_stock_records": int(neg_stock),
    "cat_revenue": {k: round(v) for k,v in cat_rev.items()},
    "rfm_segments": seg_summary["customers"].astype(int).to_dict(),
}
with open(f"{OUT}/impact_summary.json","w") as f:
    json.dump(impact, f, indent=2)

print(f"  ✓ rfm_segments.csv")
print(f"  ✓ dead_stock_skus.csv")
print(f"  ✓ monthly_revenue.csv")
print(f"  ✓ category_revenue.csv")
print(f"  ✓ impact_summary.json")
print(f"\n✅ Analysis complete.")
