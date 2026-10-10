import shutil
import os
import sys
import re

error_map = ["", "Invalid component synthesized. Please contact TA.", "Timing violation", "CPI tests are timing out"]

def output_test_results(base, verbose=False):
    test_results = {}
    with open(f"{base}/run_all_sims_result.txt") as f:
        lines = f.readlines()
        i = 0
        while i < len(lines)-1:
            line = lines[i]
            # Check if line matches "Running make [NAME]:"
            match = re.search(r"Running make (\S+): (\S+)", line)
            if match:
                test_name = match.group(1)
                # Look ahead for Passed or Failed in the following lines
                test_results[test_name] = match.group(2) == "Passed"
            if verbose:
                print(line, end='')
            i += 1
        return test_results, lines[-1] == "All tests passed!"

def output_fom_results(fom_file, verbose=False):
    errors = False
    lines = {
        "fmax": "Fmax: ",
        "integer_cpi": "Integer CPI: ",
        "fp_cpi": "Floating Point CPI: ",
        "cost": "Cost: ",
        "fom": "FOM: "
    }
    data = dict()
    with open(fom_file) as f:
        for line in f:
            if "Please report to TA" in line:
                errors = 1
                print("ERROR:", line[:-1])
            if "ERROR: Negative slack. Timing violated" in line:
                errors = 2
                if verbose:
                    print("ERROR: Design has negative slack")
            if "Timeout" in line:
                if verbose:
                    print("ERROR: CPI tests timed out")
                errors = 3 
            for k in lines:
                if line.startswith(lines[k]):
                    data[k] = float(line[len(lines[k]):])
    if "fom" not in data:
        if verbose:
            print("ERROR: FOM was not found, one of the previous steps is failing")
        errors = True
    else:
        if verbose:
            for k in data:
                print(f"{lines[k]}{data[k]}")
    return (data, errors)
    

if __name__ == "__main__":

    _, errors = output_test_results("./submission", verbose=True)

    errors = errors or output_fom_results("./submission/fom.txt", verbose=True)[1]

    if errors:
        print("WARNING: This submission will NOT pass the Autograder")

