from sklearn.preprocessing import StandardScaler
from sklearn.decomposition import PCA
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from datetime import date
import os
import csv

# Code still transitioning from Mayo-specific to general (i.e., code is not finalized)
# Command to run from <mayo> python3 ../../gen_pca.py
def variance_plot(out_dir, target, num_com, y):
    fig, ax = plt.subplots()
    xi = np.arange(1, num_com, step=1)

    plt.ylim(0.0, 1.1)
    #plt.plot(xi, y, marker='x', linestyle='--', color='b')
    plt.plot(xi, y, linestyle='--', color='b')

    plt.xlabel('Number of Components')
    plt.ylabel('Cumulative Variance (%)')
    plt.title('Number of Components Needed to Explain Variance')
    plt.suptitle(f"{target}")

    plt.axhline(y=0.80, color='r', linestyle='-')
    plt.text(0.5, 0.85, '80% cut-off threshold', color = 'red', fontsize=12)

    ax.grid(axis='x')
    plt.savefig(os.path.join(out_dir, f"variance_plot_{target}.png"))

def pca(out_dir, X, target, threshold):
    # TODO: could break this function into smaller functions
    # more preprocessing -- this is training specific

    # Apply PCA to X values
    scaler = StandardScaler()
    scaled_X = scaler.fit_transform(X)

    # TODO: 100% variance a better way?
    pca = PCA()
    pc_X = pca.fit_transform(scaled_X)

    pc_X_df = pd.DataFrame(data=pc_X, columns=['PC' + str(i) for i in range(1, pca.n_components_ + 1)])
    feature_names = X.columns.tolist()

    # Finding the most important features
    explained_variance_ratio = pca.explained_variance_ratio_
    loadings = pca.components_ # each row reprensents a principal component

    num_comp = pca.components_.shape[0]

    # Get most important feature per component
    indices = [np.abs(pca.components_[i]).argmax() for i in range(num_comp)]
    names = [feature_names[indices[i]] for i in range(num_comp)]
    assert len(indices) == len(names), "Number of indices does not match number of names"

    # Retrieve "most important" data to meet the variance threshold
    # TODO: pull data of features that explain 80% of variance (likely just have to search i)
    cumsum_variance = np.cumsum(explained_variance_ratio)
    threshold_index = np.argmax(cumsum_variance >= threshold)
    most_important_features = names[:threshold_index + 1]

    unique_features = list(dict.fromkeys(most_important_features))  # Remove duplicates while preserving order
    imp_data = X[unique_features]

    # Plot variance against number of components
    variance_plot(out_dir, target, len(explained_variance_ratio) + 1, cumsum_variance)
    
    # Get the absolute value of the loading
    abs_load = np.abs(loadings)
    
    # Get the weight of all the features from the PCA
    feature_importance = np.sum(abs_load, axis = 0)

    return indices, unique_features, imp_data

def write_res_to_csv(out_dir, target, values, names):
    # Check that output directory exists
    filename = os.path.join(out_dir, f"pca_{target}.csv")
    with open(filename, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(["Component", "Feature Name"])
        for i in range(0, len(names)):
            writer.writerow([i, names[i]])
            #writer.writerow([i, names[i], values[i]])

def write_data_to_csv(out_dir, target, data):
    # Check that output directory exists
    filename = os.path.join(out_dir, f"classifier_data_{target}.csv")
    data.to_csv(filename)

def run_pca(log_dir, log_name, targets, out_dir):
    """
    Purpose:
    - Run PCA on all targets

    Parameters:
    - log_dir -- the directory where the data log files are contained, as a string
    # TODO: do we need log_name + targets?
    - log_name -- the 'template' data log file name, as a string 
    - targets -- list of patients with data logs, as a list
    - out_dir -- the directory where PCA output should be stored, as a string

    Returns:
    - names: names of most important feature from each component, as a list

    Assumes:
    - log_dir contains only data log files in CSV format
    - log_name suffix is f"_{target}"
    """

    # Check that the logging directory exists and is not empty
    if os.path.isdir(log_dir) and os.listdir(log_dir) != []:
        if not os.path.exists(out_dir):
            os.makedirs(out_dir)

        #for log in log_dir:
        for target in targets:
            try:
                data = pd.read_csv(os.path.join(log_dir, f"{log_name}_{target}.csv"))
                val, names, classifier_data = pca(out_dir, data, target, 0.8)
                write_res_to_csv(out_dir, target, val, names)
                write_data_to_csv(out_dir, target, classifier_data)
                print(f"PCA complete and files produced for {target}.")
            except Exception as e:
                print(e)
                print(f"{target} not functional, moving to next target.")
                continue
    else:
        print(f"{log_dir} either does not exist or does not contain files.")

# TODO: make it for one patient, and call it for all patients from helper?
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

run_pca(os.path.join("logging"), "features", targets, os.path.join("pca"))