# Fashion Retail Inventory & Customer Intelligence System

## 📌 Executive Summary
An end-to-end retail business intelligence and advanced analytics system simulating Indian fashion operations (Zara/Myntra-style) across 35 stores, 7 regions, and 3 sales channels over an 18-month period. This project builds a production-grade data pipeline—from dirty relational database validation to predictive risk modeling—to uncover **₹2.51 Crore** in hidden, recoverable business opportunities across an overall portfolio volume of **₹33.32Cr**.

---

## 📈 Key Business Impacts Discovered
*   **Inventory Optimization:** Identified 67 dead-stock SKUs (avg. sell-through 3.9%) with **₹88L** stranded at cost—modeling a **₹77.1L** gross margin recovery via a 25% markdown trigger window applied before day 63 on the shelf.
*   **Customer Retention:** Segmented 4,999 customers into 7 RFM tiers using Python; flagged 772 high-value "At-Risk" customers (avg. LTV ₹76,854) representing **₹5.93Cr** revenue at churn risk.
*   **Return Risk Mitigation:** Built a Decision Tree classifier (ROC-AUC 0.62) isolating *Footwear + Online Channel + Discounts > 40%* as the primary risk profile, supporting a policy recommendation to reduce the return window from 30 to 15 days to save **₹55.4L** in refunds and restocking.
*   **Demand Forecasting:** Quantified a **3.1× festive season revenue uplift** (Oct–Nov: ₹15.2L daily avg vs. ₹4.8L regular layout), justifying a 6-week advance inventory build to eliminate peak stockout risks.

---

## 🛠️ Tech Stack & Architecture
*   **Database & Querying:** SQL Server (CTEs, Window Functions, Multi-table Joins, Data Validation)
*   **Data Processing & ML:** Python (Pandas, NumPy, Scikit-Learn Decision Trees)
*   **Business Intelligence:** Power BI (DAX, Power Query, Star Schema Data Modeling)

---

## 🔍 Data Quality Audit Pipeline (SQL)
Before running analytical scripts, a strict multi-stage data validation logic was executed across an **8-table relational schema (88,344 total rows)** to handle real-world ERP discrepancies:
*   **Raw Transactions Audited:** 55,825 rows
*   **Duplicate Transactions Removed:** 825 rows
*   **Clean Analysis-Ready Records:** 55,000 rows
*   **Negative Stock Records Corrected:** 662 rows
*   **Null Customer IDs Segmented:** 3,944 rows (7.1%)
*   **Null Payment Methods Flagged:** 2,292 rows (4.1%)

---

## 📂 Repository Contents
*   `/sql_queries/` - 9 production-grade analytical scripts using CTEs, rolling averages, and window functions (`LAG`, `RANK`, `NTILE`).
*   `/python/` - Python scripts for Pandas RFM segmentation and the Return Risk Decision Tree classifier.
*   `/dashboard/` - 5-page Power BI dashboard file utilizing complex DAX (`CALCULATE`, `DIVIDE`, `FORMAT`), KPI cards, and custom matrix layouts.
