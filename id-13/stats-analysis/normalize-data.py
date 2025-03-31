import pandas as pd

df = pd.read_csv('matlab_profile_2b.csv')
missing_data = df[df[['Timestamp', 'CPUs', 'Area', 'Value']].isnull().any(axis=1)]
print("Rows with missing data:")
print(missing_data)
df = df.dropna(subset=['Timestamp'])  # Remove rows where Timestamp couldn't be converted
df_clean = df[['Timestamp', 'CPUs', 'Area', 'Value']].copy() #removing the description and unit column
df_clean['Metric'] = df_clean['CPUs'] + '.' + df['Area'] #combining both of the cpu and metric

df_clean['Timestamp'] = pd.to_numeric(df['Timestamp'], errors='coerce')
pivot = df_clean.pivot(index = 'Timestamp', columns='Metric', values='Value')
pivot = pivot.sort_index()
pivot_filled = pivot.ffill()

pivot.to_csv('id_1_normalized_metrics.csv')
pivot_filled.to_csv('id_1_normalized_metrics_filled.csv')