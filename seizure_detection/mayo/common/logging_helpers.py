import os
import json
import csv

# Global configuration variable for toggling print modes
PRINT_FEATURE_VALUES = True  # Set to False to print only feature names

# Read the settings file to get the logging directory
with open('SETTINGS.json') as f:
    settings = json.load(f)
logging_directory = settings.get('logging-dir')

# Ensure the logging directory exists
if logging_directory and not os.path.exists(logging_directory):
    os.makedirs(logging_directory)

def get_log_filename(patient_id):
    if logging_directory is None:
        raise ValueError("Logging directory is not set.")
    return os.path.join(logging_directory, f'feature_log_{patient_id}.csv')

def write_headers_if_not_exist(filename, headers):
    if not os.path.exists(filename):
        with open(filename, 'w', newline='') as f:
            writer = csv.writer(f)
            writer.writerow(headers)

def write_features_to_csv(filename, feature_names, transformed_data=None):
    with open(filename, 'a', newline='') as f:
        writer = csv.writer(f)
        if PRINT_FEATURE_VALUES and transformed_data is not None:
            # Printing feature name and its value
            for name, value in zip(feature_names, transformed_data.ravel()):
                writer.writerow([name, value])
        else:
            # Printing just the feature name
            for name in feature_names:
                writer.writerow([name])
