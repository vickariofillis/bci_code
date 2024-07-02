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

    pca = PCA()
    pc_X = pca.fit_transform(scaled_X)

    pc_X_df = pd.DataFrame(data=pc_X, columns=['PC' + str(i) for i in range(1, pca.n_components_ + 1)])
    feature_names = X.columns.tolist()

    # Finding the most important features
    explained_variance_ratio = pca.explained_variance_ratio_
    loadings = pca.components_ # each row reprensents a principal component
    # Get the absolute value of the loading
    abs_load = np.abs(loadings)

    num_comp = pca.components_.shape[0]

    # Get most important feature per component
    indices = [abs_load[i].argmax() for i in range(num_comp)]
    names = [feature_names[indices[i]] for i in range(num_comp)]
    assert len(indices) == len(names), "Number of indices does not match number of names"

    # Retrieve "most important" data to meet the variance threshold
    sum_variance = np.cumsum(explained_variance_ratio)
    threshold_index = np.argmax(sum_variance >= threshold)
    most_important_features = names[:threshold_index + 1]

    unique_features = list(dict.fromkeys(most_important_features))  # Remove duplicates while preserving order
    csv_data = X[unique_features]

    # Write classifier data to CSV
    write_data_to_csv(out_dir, target, csv_data)

    #classifier_data = csv_data.to_numpy()
    # Convert DataFrame to list
    classifier_data = csv_data.to_numpy()

    # Plot variance against number of components
    variance_plot(out_dir, target, len(explained_variance_ratio) + 1, sum_variance)
    
    # Get the weight of all the features from the PCA
    # feature_importance = np.sum(abs_load, axis = 0)

    return unique_features, classifier_data

def write_res_to_csv(out_dir, target, names):
    # Check that output directory exists
    filename = os.path.join(out_dir, f"pca_{target}.csv")
    with open(filename, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(["Component", "Feature Name"])
        for i in range(0, len(names)):
            writer.writerow([i, names[i]])

def write_data_to_csv(out_dir, target, data):
    # Check that output directory exists
    filename = os.path.join(out_dir, f"classifier_data_{target}.csv")
    data.to_csv(filename, index=False, header=False)

def run_pca(log_dir, log_name, target, out_dir):
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
        try:
            data = pd.read_csv(os.path.join(log_dir, f"{log_name}_{target}.csv"))
            names, classifier_data = pca(out_dir, data, target, 0.8)
            write_res_to_csv(out_dir, target, names)
            print(f"PCA complete and files produced for {target}.")
            return classifier_data
        except Exception as e:
            print(e)
            print(f"{target} not functional.")
    else:
        print(f"{log_dir} either does not exist or does not contain files.")

def pca_direct(X, threshold, num_ictal, num_interictal, target):
    # TODO: could break this function into smaller functions
    # more preprocessing -- this is training specific
    
    # Apply PCA to X values
    scaler = StandardScaler()
    scaled_X = scaler.fit_transform(X)

    pca = PCA(0.80)
    pc_X = pca.fit_transform(scaled_X)

    pc_X_df = pd.DataFrame(data=pc_X, columns=['PC' + str(i) for i in range(1, pca.n_components_ + 1)])
    num_rows, num_cols = X.shape
    feature_names = [f"{i}" for i in range(0, num_cols)] # can remove and parse when defining names

    # Finding the most important features
    explained_variance_ratio = pca.explained_variance_ratio_
    loadings = pca.components_ # each row reprensents a principal component
    # Get the absolute value of the loading
    abs_load = np.abs(loadings)

    num_comp = pca.components_.shape[0]
    num_features = pca.components_.shape[1]

    # Get most important feature per component
    indices = [abs_load[i].argmax() for i in range(0, num_comp)]
    indices_to_delete = [i for i in range(0, num_features) if i not in indices]
    names = [feature_names[indices[i]] for i in range(0, num_comp)]
    assert len(indices) == len(names), "Number of indices does not match number of names"

    # Write most important features to CSV
    filename = os.path.join("pca", f"pca_{target}.csv")
    with open(filename, 'w') as f:
        write = csv.writer(f)
        for name in names:
            write.writerow([name])

    # Get most important features by deleting the non-important ones
    X = np.delete(X, indices_to_delete, axis=1)

    new_ictal = X[:num_ictal][:]
    new_interictal = X[num_ictal:][:]
    
    return new_ictal, new_interictal

def pca_test(X, target):
    # Run PCA on  test data

    important_features_indices = []
    filename = os.path.join("pca", f"pca_{target}.csv")
    
    with open(filename, 'r') as f:
        read = csv.reader(f)
        for row in read:
            important_features_indices.append(int(row[0]))
    
    indices_to_delete = [i for i in range(0, X.shape[1]) if i not in important_features_indices]

    X = np.delete(X, indices_to_delete, axis=1)

    return X

def run_direct_pca(ictal_X, interictal_X, target):
    # Combine ictal and interictal data to run PCA on data as a 'whole'
    full_X = np.concatenate((ictal_X, interictal_X), axis=0)
    return pca_direct(full_X, 0.80, len(ictal_X), len(interictal_X), target)