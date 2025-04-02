import pandas as pd
import matplotlib.pyplot as plt
from sklearn.preprocessing import StandardScaler
from sklearn.decomposition import PCA
import seaborn as sns
import argparse

#parser = argparse.ArgumentParser(description="Perform PCA on PMU metric CSV")
#parser.add_argument("input_csv", help="Path to standardized CSV")
#parser.add_argument("--n_components", type=int, default=5, help="Number of PCA components to keep")
#parser.add_argument("--output_plot", default="pca_variance.png", help="Filename for the PCA variance plot")
#args = parser.parse_args()

# Load CSV
df = pd.read_csv("id-13-pmu-standardized.csv") #args.input_csv)
#df = pd.read_csv("id-13-pmu-standardized.csv") #args.input_csv)

# Drop non-numeric or non-feature columns
features = df.drop(columns=['Timestamp'], errors='ignore')

# Fill missing values (optional - you may also choose to drop them)
features = features.fillna(0)

# Standardize features
scaler = StandardScaler()
features_scaled = scaler.fit_transform(features)

# Run PCA
n_components = 10
pca = PCA(n_components=10)
pca_result = pca.fit_transform(features_scaled)

# Variance explained
explained_variance = pca.explained_variance_ratio_
print("Explained variance ratio by component:", explained_variance)
explained_variance_df = pd.DataFrame({
    "Principal Component": [f"PC{i+1}" for i in range(n_components)],
    "Explained Variance Ratio": explained_variance
})
explained_variance_df.to_csv("pca_explained_variance.csv", index=False)

# Plot explained variance
plt.figure(figsize=(8, 5))
sns.barplot(x=[f"PC{i+1}" for i in range(10)], y=explained_variance)
plt.ylabel("Variance Explained")
plt.xlabel("Principal Components")
plt.title("PCA - Explained Variance by Component")
plt.tight_layout()
plt.savefig("pca_plot.png")
plt.show()

loadings = pd.DataFrame(
    pca.components_,
    columns=features.columns,
    index=[f"PC{i+1}" for i in range(n_components)]
)

top_k = 6  # Top-k contributors per component
summary_rows = []

for i, pc in enumerate(loadings.index):
    sorted_loadings = loadings.loc[pc].abs().sort_values(ascending=False)
    for rank in range(top_k):
        metric = sorted_loadings.index[rank]
        value = loadings.loc[pc, metric]
        summary_rows.append({
            "Principal Component": pc,
            "Explained Variance Ratio": explained_variance[i],
            "Rank": rank + 1,
            "Metric": metric,
            "Loading": value
        })

summary_df = pd.DataFrame(summary_rows)
summary_df.to_csv("pca_top_metrics.csv", index=False)