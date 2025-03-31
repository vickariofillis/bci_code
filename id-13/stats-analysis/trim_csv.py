import pandas as pd
import sys

# Usage: python3 trim_csv_columns.py input.csv output.csv 5

input_file = sys.argv[1]
output_file = sys.argv[2]
num_columns = int(sys.argv[3])

# Load the CSV
df = pd.read_csv(input_file)

# Keep only the first N columns
df_trimmed = df.iloc[:, :num_columns]

# Save the trimmed CSV
df_trimmed.to_csv(output_file, index=False)

print(f"Saved {num_columns} columns to {output_file}")
