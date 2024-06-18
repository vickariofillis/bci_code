import os
import json
import csv
import numpy as np

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
    return os.path.join(logging_directory, f'features_{patient_id}.csv')

def write_headers_to_csv(filename, headers):
    if not os.path.exists(filename):
        with open(filename, 'w', newline='') as f:
            writer = csv.writer(f)
            writer.writerow(headers)

def write_features_to_csv(filename, feature_names, transformed_data=None):
    with open(filename, 'a', newline='') as f:
        writer = csv.writer(f)
        if transformed_data is not None:
            writer.writerow(transformed_data.ravel())
