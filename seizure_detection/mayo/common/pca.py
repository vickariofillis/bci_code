from sklearn.preprocessing import StandardScaler
from sklearn.decomposition import PCA
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from datetime import date

targets = [
        'Dog_1',
        'Dog_2',
        'Dog_3',
        'Dog_4',
        'Patient_1',
        'Patient_2',
        'Patient_3',
        'Patient_4',
        'Patient_5',
        'Patient_6',
        'Patient_7',
        'Patient_8'
    ]

def variance_plot(target, num_com, y):
    fig, ax = plt.subplots()
    xi = np.arange(1, num_com, step=1)

    plt.ylim(0.0,1.1)
    plt.plot(xi, y, marker='x', linestyle='--', color='b')

    plt.xlabel('Number of Components')
    plt.xticks(np.arange(0, num_com, step=1)) #change from 0-based array index to 1-based human-readable label
    plt.ylabel('Cumulative variance (%)')
    plt.title('Number of Components Needed to Explain Variance')
    plt.suptitle(f"{target}")

    plt.axhline(y=0.80, color='r', linestyle='-')
    plt.text(0.5, 0.85, '80% cut-off threshold', color = 'red', fontsize=12)

    ax.grid(axis='x')
    plt.show()

    plt.savefig(f"logging/{target}_pca.png")

# Function to write select processing steps to a txt file
def steps(num, output, patient):
    # Set name for file
    today = date.today()

    # Formatting dividers
    div1 = "-" * 20
    div2 = "*" * 50

    # Write to file
    f = open(f"logging/ProcessSteps_Patient{patient}_{str(today.strftime('%b%d-%H%M'))}.txt", "w")
    for step in output:
        f.write(f"{step}\n{output[step][0]}\n{div1}\n{str(output[step][1])}\n{div2}\n")
    f.close()

def pca(X, target):
    # TODO: could break this function into smaller functions
    # more preprocessing -- this is training specific

    results = {'# of features': [], 'features_idx': [], 'SVM accuracy': [], 'MLP accuracy': [], 'SVM rates': [], 'MLP rates': []}
    writeout = {}

    # Apply PCA to X values
    scaler = StandardScaler()
    scaled_X = scaler.fit_transform(X)
    pca = PCA(0.80)
    pc_X= pca.fit_transform(scaled_X)

    pc_X_df = pd.DataFrame(data = pc_X, columns = ['PC' + str(i) for i in range(1, pca.n_components_ + 1)])
    scale_factor = 10
    scaled_pc_X = (pc_X * scale_factor).astype(int)
    feature_names = X.columns.tolist()

    # Finding the most important features
    explained_variance_ratio = pca.explained_variance_ratio_
    loadings = pca.components_ # each row reprensents a principal component
    writeout["Explained Variance Ratio"] = ["Vector of the variance explained by each dimension", pca.explained_variance_ratio_]
    
    # Plot variance against number of components
    variance_plot(target, len(explained_variance_ratio) + 1, np.cumsum(explained_variance_ratio))

    # get the absolute value of the loading
    abs_load = np.abs(loadings)
    writeout["Absolute Loadings"] = ["How much each feature influences a principal component (each row is a principal component)", abs_load]

    # get the weight of all the features from the PCA
    feature_importance = np.sum(abs_load, axis = 0)

    # sort the index of the feature importance in descending order
    # biggest features show up first
    sorted_idx = np.argsort(feature_importance)[::-1]
    writeout["Sorted IDX"] = ["List of indices of the features, sorted in descending order of importance", sorted_idx]

    #for n_ft in range(1, len(X.columns)): # This one is to run through all features (~510)
    for n_ft in range(1, 5): # This one is for testing
        # get n_ft most important features
        most_important_feature = sorted_idx[:n_ft]
        # get the new columns from the PCA
        new_columns = []
        ft_id = []
        for j in most_important_feature:
            new_columns.append(feature_names[j])
            name = str(feature_names[j])
            ft_id.append(f"{name} (ID: {j})")
        #new_df = res[new_columns]
        writeout["Post-PCA Data"] = ["Data used to determine train-test splits (after some scaling/transforming)", new_df]

        # results = {'# of features': [], 'features': [], 'SVM accuracy': [], 'MLP accuracy': []}
        results['# of features'].append(n_ft)
        results['features_idx'].append(ft_id)

        steps(n_ft, writeout, target)

    return results

def pca_all_targets(targets):
    for target in targets:
        try:
            data = pd.read_csv(f"logging/feature_log_{target}.csv")
            res = pca(data, target)
            print(res)
        except:
            print(f"{target} not functional, moving to next target.")
            continue

pca_all_targets(targets)
