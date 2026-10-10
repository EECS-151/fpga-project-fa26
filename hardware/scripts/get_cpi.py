#!/usr/bin/env python3

from run_fpga import run_fpga
from subprocess import Popen, PIPE
import numpy as np
import os
import argparse

benchmark_path = '../software/benchmark'

def get_cpi_sim():
  print('Running simulation...')
  p = Popen('make small-tests -B', shell=True, stdout=PIPE, stderr=PIPE)
  stdout, stderr = p.communicate()
  lines = stdout.decode('ascii', errors='ignore').splitlines()

  # Hardcoding the fact that small-tests only runs three tests,
  # and that the third one is fpmmult

  cyc_cnts = []
  inst_cnts = []
  for line in lines[2:]:
    line = line.strip()
    print(line)
    if line.startswith('Cycle Count:'):
      cyc_cnts.append(int(line.split()[2], 16))
    elif line.startswith('Instruction Count:'):
      inst_cnts.append(int(line.split()[2], 16))
  print('...simulation complete')
  print('Cycle Counts: {}'.format(cyc_cnts))
  print('Instruction Counts: {}'.format(inst_cnts))
  if len(cyc_cnts) != len(inst_cnts) or len(cyc_cnts) != 3:
    print('Error: got {} cycle counts and {} instruction counts, expecting 3'.format(len(cyc_cnts), len(inst_cnts)))
    return None
  integer_cpi = ((cyc_cnts[0] / inst_cnts[0]) * (cyc_cnts[1] / inst_cnts[1])) ** 0.5
  print('Estimated Integer CPI (geomean): {:.2f}'.format(integer_cpi))
  fp_cpi = cyc_cnts[2] / inst_cnts[2]
  print('Estimated Floating Point CPI: {:.2f}'.format(fp_cpi))
  return (integer_cpi, fp_cpi)

def get_cpi(port, com):

  print('Running on FPGA...')
  benchmarks = ["bdd", "mmult"]
  cyc_cnts = []
  inst_cnts = []
  for benchmark in benchmarks:
    cycle_count, inst_count = run_fpga(os.path.join(benchmark_path, benchmark, benchmark + '.hex'), port, com)
    cyc_cnts.append(cycle_count)
    inst_cnts.append(inst_count)
  print('...FPGA run complete')
  print('Cycle Counts: {}'.format(cyc_cnts))
  print('Instruction Counts: {}'.format(inst_cnts))
  cyc_cnts = np.array(cyc_cnts)
  inst_cnts = np.array(inst_cnts)
  cpis = cyc_cnts / inst_cnts
  np.set_printoptions(precision=2)
  print('CPIs: ' + np.array2string(cpis, separator=', '))
  integer_cpi = cpis.prod()**(1.0/len(cpis))
  print('Integer CPI (geomean): {:.2f}'.format(integer_cpi))

  cycle_count, inst_count = run_fpga("../software/fpmmult/fpmmult.hex", port, com)

  fp_cpi = cycle_count / inst_count
  print('FP CPI (geomean): {:.2f}'.format(fp_cpi))

  return (integer_cpi, fp_cpi)


if __name__ == '__main__':
  parser = argparse.ArgumentParser()
  parser.add_argument('-r', '--run', action="store_true")
  parser.add_argument('--port_name', action="store", type=str, default='/dev/ttyUSB0')
  parser.add_argument('--com_name', action="store", type=str, default='COM11')
  args = parser.parse_args()
  if args.run:
    get_cpi(args.port_name, args.com_name)
  else:
    get_cpi_sim()
