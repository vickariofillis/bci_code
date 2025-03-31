import pandas as pd


#want to name format to be id_X_Y where X is id number, and Y is the data number
df = pd.read_csv('matlab_profile_2b.csv')

#determining which metrics are always 0
area_all_zero = df.groupby('Area')['Value'].apply(lambda x: (x == 0).all()).reset_index()
area_all_zero.columns = ['Metric', 'IsAllZero']
area_all_zero.to_csv('completely_zero_metrics.csv')

#determining which metrics are 0 by cpus
grouped = df.groupby(['CPUs', 'Area'])
cpu_area_all_zero_metrics = []

for (cpu, area), group in grouped:
    values = group['Value']
    if (values == 0).all(): #check iif all values are exactly zero
        cpu_area_all_zero_metrics.append({
            'CPU': cpu,
            'Metric': area,
            'Num Samples': len(values)
        })

zero_df = pd.DataFrame(cpu_area_all_zero_metrics)

print("Metrics with all-zero values across all samples:")
print(zero_df.sort_values(by=['CPU', 'Metric']))

zero_df.to_csv('per_cpu_zero_metrics.csv', index=False)

#determining which per cpu metrics that are 0 are not always 0; whcih cpus are they 0 on
completely_zero_metrics_set = set(area_all_zero[area_all_zero['IsAllZero']]['Metric'])
partial_zero_df = zero_df[~zero_df['Metric'].isin(completely_zero_metrics_set)]
summary = partial_zero_df.groupby('Metric')['CPU'].agg(['count', list]).reset_index()
summary.columns = ['Metric', 'NumCPUs_AllZero', 'CPUs_AllZero']
summary.to_csv('partially_zero_metrics_summary.csv', index=False)