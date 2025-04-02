import pandas as pd
import matplotlib.pyplot as plt

metrics_df = pd.read_csv('id-13-pmu-standardized.csv')
pca_df = pd.read_csv('pca_top_metrics.csv')
grouped = pca_df.groupby('Principal Component')

for pc, group in grouped:
    top_metrics = group['Metric'].tolist()
    
    # Plotting
    plt.figure(figsize=(12, 6))
    for metric in top_metrics:
        if metric in metrics_df.columns:
            plt.plot(metrics_df['Timestamp'], metrics_df[metric], label=metric)
        else:
            print(f"Warning: {metric} not found in metrics.csv columns.")
    plt.title(f'Top Metrics for {pc}')
    plt.xlabel('Runtime (s)')
    plt.ylabel('Metric Value')
    plt.legend()
    plt.grid(True)
    plt.tight_layout()
    plt.savefig(f'id13_{pc}_top_metrics_plot.png')  # Save plot as PNG
    plt.show()