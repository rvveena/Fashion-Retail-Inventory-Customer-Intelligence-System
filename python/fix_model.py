import pandas as pd
import numpy as np

txn  = pd.read_excel('data/fact_transactions.xlsx', parse_dates=['transaction_date'])
prod = pd.read_excel('data/dim_products.xlsx')
txn  = txn.merge(prod[['product_id','category','heat_score']], on='product_id', how='left')

np.random.seed(42)
txn['return_prob'] = 0.05
txn.loc[txn['category']=='Footwear',  'return_prob'] += 0.12
txn.loc[txn['category']=='Dresses',   'return_prob'] += 0.07
txn.loc[txn['category']=='Outerwear', 'return_prob'] += 0.05
txn.loc[txn['discount_pct'] > 0.40,   'return_prob'] += 0.10
txn.loc[txn['discount_pct'] > 0.25,   'return_prob'] += 0.05
txn.loc[txn['quantity'] >= 3,         'return_prob'] += 0.08
txn.loc[txn['heat_score']=='dead',    'return_prob'] += 0.06
txn.loc[txn['channel']=='Online',     'return_prob'] += 0.06

txn['is_returned'] = (np.random.random(len(txn)) < txn['return_prob']).astype(int)
txn.drop(columns=['category','heat_score','return_prob'], inplace=True)
txn.to_csv('data/fact_transactions.csv', index=False)

print('Done. Return signal injected.')
print(f'Return rate: {txn["is_returned"].mean()*100:.1f}%')