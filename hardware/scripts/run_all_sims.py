#!/usr/bin/env python3
"""Run the CPU's RTL testbenches and check their results.

Builds the software they run first. Prints one "Running make <target>: Passed|Failed" line per
testbench, and ends with "All tests passed!" only if every one passed (scripts/pre_autograder.py
reads this output). Each testbench's make output goes to test_results/. Runs from any directory.
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

HARDWARE = Path(__file__).resolve().parent.parent
SOFTWARE = HARDWARE.parent / 'software'
SIM = HARDWARE / 'sim'
RESULT_DIR = HARDWARE / 'test_results'
ISA_SOURCES = SOFTWARE / 'riscv-isa-tests/riscv-tests/isa/rv32ui'
ISA_EXEMPT = ('fence_i', 'ma_data')     # ISA tests the CPU need not pass


def isa_tests():
    return sorted(p.stem for p in ISA_SOURCES.glob('*.S') if p.stem not in ISA_EXEMPT)


def c_tests():
    return sorted(p.stem for p in (SOFTWARE / 'c_tests').glob('*/*.c'))


def build_software():
    """Builds every program the testbenches load. Returns what went wrong (empty if nothing)."""
    if not any(ISA_SOURCES.glob('*.S')):
        return ['the riscv-tests submodule is not checked out: run git submodule update --init']
    dirs = [SOFTWARE / d for d in ('asm', 'echo', 'uart_parse', 'bios')]
    dirs += sorted(p.parent for p in (SOFTWARE / 'c_tests').glob('*/Makefile'))
    dirs += [SOFTWARE / 'riscv-isa-tests']
    for d in dirs:
        proc = subprocess.run(['make', '-C', str(d)], capture_output=True, universal_newlines=True, errors='replace')
        if proc.returncode:
            return ['make -C {} failed:'.format(d), proc.stdout + proc.stderr]
    return []


def missing_passes(log_dir, tests, pass_string):
    """The tests whose log doesn't report a pass (a missing log counts: a test that never ran
    hasn't passed)."""
    problems = []
    for t in tests:
        log = log_dir / (t + '.log')
        if not log.is_file():
            problems.append('{}: did not run'.format(t))
        elif pass_string not in log.read_text(errors='replace'):
            problems.append('{}: did not pass (see {})'.format(t, log))
    return problems


def single_tb(name, pass_string):
    """A testbench run with make sim/<name>.fsdb that passes if its output has pass_string."""
    def cleanup():
        for ext in ('tb', 'fsdb', 'log'):
            p = SIM / '{}.{}'.format(name, ext)
            if p.exists():
                p.unlink()

    def problems(stdout):
        return [] if pass_string in stdout else ['"{}" not in the output'.format(pass_string)]

    return 'sim/{}.fsdb'.format(name), cleanup, problems


TESTBENCHES = [
    single_tb('cpu_tb', 'All tests passed!'),
    single_tb('asm_tb', 'ALL ASSEMBLY TESTS PASSED!'),
    ('isa-tests', lambda: shutil.rmtree(str(SIM / 'isa'), ignore_errors=True),
     lambda _: missing_passes(SIM / 'isa', isa_tests(), '[passed]')),
    ('c-tests', lambda: shutil.rmtree(str(SIM / 'c_tests'), ignore_errors=True),
     lambda _: missing_passes(SIM / 'c_tests', c_tests(), 'CSR test PASSED!')),
    single_tb('echo_tb', 'Test passed!'),
    single_tb('uart_parse_tb', 'CSR test PASSED! Strings matched.'),
    single_tb('bios_tb', 'BIOS testbench done! Num failed tests:          0'),
]


def run_bench(target, cleanup, problems_of, continue_on_error):
    """Runs make <target> in hardware/ and checks it. Returns whether it passed."""
    print('Running make {}: '.format(target), end='', flush=True)
    cleanup()
    proc = subprocess.run(['make', target], cwd=str(HARDWARE), capture_output=True,
                          universal_newlines=True, errors='replace')
    name = target.split('/')[-1]
    (RESULT_DIR / (name + '.out')).write_text(proc.stdout)
    (RESULT_DIR / (name + '.err')).write_text(proc.stderr)
    if proc.returncode:
        problems = ['make exited with status {}'.format(proc.returncode)]
    else:
        problems = problems_of(proc.stdout)
    if not problems:
        print('Passed')
        return True
    print('Failed')
    for p in problems:
        print('  ' + p)
    if not continue_on_error:
        print('stdout:')
        print(proc.stdout)
        print('stderr:')
        print(proc.stderr)
        print('See {} for logs'.format(RESULT_DIR))
        sys.exit(1)
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('-c', '--continue-on-error', action='store_true',
                        help='run every testbench even after one fails')
    args = parser.parse_args()
    RESULT_DIR.mkdir(exist_ok=True)

    print('Building software: ', end='', flush=True)
    problems = build_software()
    if problems:
        print('Failed')
        for p in problems:
            print('  ' + p)
        print('Some tests failed')
        sys.exit(1)
    print('Passed')

    passed = [run_bench(*tb, args.continue_on_error) for tb in TESTBENCHES]
    if all(passed):
        print('All tests passed!')
    else:
        print('Some tests failed')
        sys.exit(1)


if __name__ == '__main__':
    main()
