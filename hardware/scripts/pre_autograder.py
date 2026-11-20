import os
import sys

# Indexed by the error code output_fom_results returns
error_map = ["", "Invalid component synthesized. Please contact TA.", "Timing violation", "CPI tests are timing out",
             "FOM was not found, one of the previous steps is failing"]

def output_fom_results(fom_file, verbose=False):
    """Returns (the values in scripts/fom.py's results file, an error code: an index into error_map, 0 if none)."""
    errors = 0
    lines = {
        "fmax": "Fmax (MHz): ",
        "cpi": "CPI: ",
        "t2t": "T_t2t (ns): ",
        "cost": "Cost: ",
        "fom": "FOM: "
    }
    data = dict()
    if not os.path.isfile(fom_file):
        print(f"ERROR: {fom_file} not found: run scripts/fom.py")
        return (data, 4)
    with open(fom_file) as f:
        for line in f:
            if "Please report to TA" in line:
                errors = 1
                print("ERROR:", line.rstrip())
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
        errors = errors or 4
    elif verbose:
        for k in data:
            print(f"{lines[k]}{data[k]}")
    return (data, errors)


if __name__ == "__main__":
    # The autograder takes the results file scripts/fom.py writes (fom.txt by default)
    fom_file = sys.argv[1] if len(sys.argv) > 1 else "fom.txt"
    if output_fom_results(fom_file, verbose=True)[1]:
        print("WARNING: This submission will NOT pass the Autograder")
