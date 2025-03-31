import pandas as pd
import numpy as np
import argparse

#going to average the values witihn the buckets of time
parser = argparse.ArgumentParser(description="Standardize time into 100 intervals and average values within each.")
parser.add_argument("input_csv")
parser.add_argument("output_csv") #standardized csv

args = parser.parse_args()

df = pd.read_csv(args.input_csv)

# Ensure Timestamp is float
df['Timestamp'] = df['Timestamp'].astype(float)

# Compute 100 bins
min_t, max_t = df['Timestamp'].min(), df['Timestamp'].max()
bins = np.linspace(min_t, max_t, 101)  # 101 edges for 100 bins

# Assign each row to a bin
df['time_bin'] = pd.cut(df['Timestamp'], bins=bins, labels=False, include_lowest=True)

# Group by bin and average
# Drop Timestamp + CPU during averaging; we keep Timestamp as the midpoint of each bin
metrics_cols = [col for col in df.columns if col not in ['Timestamp', 'CPU', 'time_bin']]
grouped = df.groupby('time_bin')[metrics_cols].mean()

# Use bin midpoints as new timestamps
midpoints = (bins[:-1] + bins[1:]) / 2
grouped.insert(0, 'Timestamp', midpoints)


grouped.to_csv(args.output_csv, index=False)
print(f"Saved standardized 100-timestep CSV to: {args.output_csv}")
