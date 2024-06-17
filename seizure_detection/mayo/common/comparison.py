import csv
import os
import cmath

# TODO: fix to import from initial declaration?
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

def read_log_file(filename):
    '''
    Read in log file produced with feature names and values
    '''
    with open(filename) as f:
        csv_reader = csv.reader(f, delimiter = ',')
        
        # Skip header row
        next(csv_reader)

        # Instantiate dictionary to store data as feature name: feature value
        data = {}

        i = 0

        # Collect all data from the CSV file
        for row in csv_reader:
            value = row[1]
            if "j" in value:
                if "(" in value:
                    value = value[1:-1]
                value = complex(value)
            else:
                value = float(value)
            data[i] = [row[0], value]
            i += 1
        # data = {0: [name, value], ...}

    return data
##print val before and after, plus type
def read_pipeline_file(filename):
    '''
    Read in pipeline output file produced with feature values
    '''
    with open(filename) as f:
        csv_reader = csv.reader(f, delimiter = ',')

        # Instantiate list to store data
        data = []

        # Collect all data from the CSV file
        for row in csv_reader:
            row = row[0]
            if "j" in row:
                if "(" in row:
                    row = row[1:-1]
                row = complex(row)
            else:
                row = float(row)
            data.append(row)

    return data

def compare_output(log_name, pipe_name):
    log_data = read_log_file(log_name)
    pipe_data = read_pipeline_file(pipe_name)

    res = {}
    i = 0

    # TODO: Add index?
    for pipe_val in pipe_data:
        #occurrences = [name for (name, log_val) in log_data.items() if ((cmath.isclose(pipe_val, log_val, abs_tol=0.001) or (pipe_val == log_val)))]
        occurrences = []
        for j in log_data:
            name = log_data[j][0]
            log_val = log_data[j][1]
            if isinstance(log_val, (int, float, complex)):
                if cmath.isclose(pipe_val, log_val, abs_tol = 0.0000000001) or pipe_val == log_val:
                    occurrences.append((name, j))
                    print("GOT ONE", j)
        res[i] = [pipe_val, occurrences]
        i += 1

    return res

def write_comparison_to_csv(data, target):
    with open(f"logging/{target}_log_pipe_comparison.csv", 'w', newline='') as f:
        writer = csv.writer(f)
        for row in data:
            writer.writerow(data[row])

def main():
    # Go through each patient
    for id in targets:
        log_file = f"logging/feature_log_{id}.csv"
        pipe_file = f"logging/pipeline_output_{id}.csv"
        # Check necessary files exist
        if os.path.isfile(log_file) and os.path.isfile(pipe_file):
            # Perform comparison and write to file
            comp = compare_output(log_file, pipe_file)
            write_comparison_to_csv(comp, id)
        else:
            print(f"{id} file(s) are missing")

main()

#2207 for 1st