import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns

#data = pd.read_csv('matlab_profile.csv', low_memory=False)
# print(data.head())

# Load CSV file
df = pd.read_csv('matlab_profile.csv')  # change to your filename

# --- Step 1: Basic Cleanup ---
# Drop rows with NaN in important columns
df = df.dropna(subset=["Timestamp", "Area", "Value"])

# Convert timestamp to float (if not already)
df["Timestamp"] = pd.to_numeric(df["Timestamp"], errors="coerce")
df["Value"] = pd.to_numeric(df["Value"], errors="coerce")



# --- Step 2: Selecting a few Metrics to Track for now ---
metrics_to_plot = [
    "Frontend_Bound",
    "Backend_Bound",
    "CoreIPC",
    "L2MPKI",
    "Load_L2_Miss",
]

# --- Step 3: Filter Data ---
# Create a dict of dataframes for each metric
metric_dfs = {
    metric: df[df["Area"] == metric][["Timestamp", "Value"]].set_index("Timestamp")
    for metric in metrics_to_plot
}

# --- Step 4: Plot ---
plt.figure(figsize=(14, 8))
for metric, data in metric_dfs.items():
    plt.plot(data.index, data["Value"], label=metric)

plt.title("Performance Metrics Over Time")
plt.xlabel("Timestamp")
plt.ylabel("Value")
plt.legend()
plt.grid(True)
plt.tight_layout()
plt.show()

# --- Step 5: Summary Statistics ---
print("\n=== Summary Statistics ===")
for metric, data in metric_dfs.items():
    print(f"\nMetric: {metric}")
    print(data["Value"].describe())

# --- Step 6: Bottleneck Detection ---
if "Bottleneck" in df.columns:
    bottlenecks = df[df["Bottleneck"].str.contains("<==", na=False)]
    print(f"\nDetected {len(bottlenecks)} bottleneck samples")
    print(bottlenecks[["Timestamp", "Area", "Value", "Bottleneck"]].head())



# # Visualizing the distribution of the 'Value' column
# plt.figure(figsize=(10, 6))
# sns.histplot(data['Value'], kde=True, bins=30)
# plt.title('Distribution of Value')
# plt.xlabel('Value')
# plt.ylabel('Frequency')
# plt.show()

# # Optional: Filter data by specific metrics (e.g., if 'Area' is a key metric)
# # For example, analyzing 'Frontend_Bound' data
# frontend_bound_data = data[data['Area'] == 'Frontend_Bound']

# # Visualize the 'Value' of Frontend_Bound
# plt.figure(figsize=(10, 6))
# sns.boxplot(x='Area', y='Value', data=frontend_bound_data)
# plt.title('Frontend Bound Value Distribution')
# plt.xlabel('Area')
# plt.ylabel('Value')
# plt.show()

# # You can repeat this for other areas or metrics, depending on what you're analyzing.
# # For example, to compare multiple 'Area' metrics:
# plt.figure(figsize=(10, 6))
# sns.boxplot(x='Area', y='Value', data=data)
# plt.title('Value Distribution Across Different Areas')
# plt.xlabel('Area')
# plt.ylabel('Value')
# plt.xticks(rotation=45)  # Rotate x-axis labels if they are long
# plt.show()

# # Correlation analysis if you have numeric columns (e.g., Value, Stddev, etc.)
# # Make sure the 'Value' column and others are numeric (they should be)
# numeric_columns = ['Value', 'Stddev']  # Replace with the actual numeric columns you want
# correlation_matrix = data[numeric_columns].corr()

# # Plotting the correlation heatmap
# plt.figure(figsize=(8, 6))
# sns.heatmap(correlation_matrix, annot=True, cmap='coolwarm', linewidths=0.5)
# plt.title('Correlation Matrix of Numeric Metrics')
# plt.show()
