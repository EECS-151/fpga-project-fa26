#!/usr/bin/env python3
import argparse
import math
import re
import subprocess
from pathlib import Path

from run_fpga import run_fpga, default_port, DEFAULT_TIMEOUT_S

HARDWARE = Path(__file__).resolve().parent.parent
SOFTWARE = HARDWARE.parent / 'software'
BENCHMARKS = ('bdd', 'mmult', 'qsort', 'sha256')


def _geomean(xs):
  return math.exp(sum(math.log(x) for x in xs) / len(xs))


def _report(cycles, insts):
  print('Cycle Counts: {}'.format(cycles))
  print('Instruction Counts: {}'.format(insts))
  cpis = {b: cycles[b] / insts[b] for b in BENCHMARKS}
  for b in BENCHMARKS:
    print('{} CPI: {:.4f}'.format(b, cpis[b]))
  cpi = _geomean(list(cpis.values()))
  print('CPI (geomean): {:.4f}'.format(cpi))
  return cpi


def get_cpi(port, com, timeout_s=DEFAULT_TIMEOUT_S):
  """CPI on the FPGA. Raises FileNotFoundError if a benchmark isn't built, TimeoutError if one
  doesn't finish."""
  print('Running on FPGA ({})...'.format(port))
  cycles, insts = {}, {}
  for b in BENCHMARKS:
    hex_file = SOFTWARE / 'benchmark' / b / (b + '.hex')
    if not hex_file.is_file():
      raise FileNotFoundError('{} not found: build it with make -C {}'.format(hex_file, SOFTWARE / 'benchmark'))
    cycles[b], insts[b] = run_fpga(str(hex_file), port, com, timeout_s)
  print('...FPGA run complete')
  return _report(cycles, insts)


def get_cpi_sim():
  """CPI estimate from the small benchmarks in simulation."""
  subprocess.run(['make', '-C', str(SOFTWARE / 'small')], check=True)
  print('Running simulation...')
  cycles, insts = {}, {}
  for b in BENCHMARKS:
    tb = b + '_small_tb'
    fsdb = HARDWARE / 'sim' / (tb + '.fsdb')
    if fsdb.exists():
      fsdb.unlink()                 # rerun even if the RTL hasn't changed
    p = subprocess.run(['make', 'sim/{}.fsdb'.format(tb)], cwd=HARDWARE, capture_output=True, text=True, errors='replace')
    cyc = re.search(r'Cycle Count:\s*([0-9a-fA-F]+)', p.stdout)
    inst = re.search(r'Instruction Count:\s*([0-9a-fA-F]+)', p.stdout)
    if p.returncode or not cyc or not inst:
      raise RuntimeError('{} printed no cycle and instruction counts: see {}'.format(tb, HARDWARE / 'sim' / (tb + '.log')))
    cycles[b], insts[b] = int(cyc.group(1), 16), int(inst.group(1), 16)
  print('...simulation complete')
  return _report(cycles, insts)


if __name__ == '__main__':
  parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
  parser.add_argument('-r', '--run', action="store_true", help='run on the FPGA instead of in simulation')
  parser.add_argument('--port_name', action="store", type=str, default=None,
                      help="serial port (default: your leased board's PMOD UART)")
  parser.add_argument('--com_name', action="store", type=str, default='COM11')
  args = parser.parse_args()
  if args.run:
    get_cpi(args.port_name or default_port(), args.com_name)
  else:
    get_cpi_sim()
