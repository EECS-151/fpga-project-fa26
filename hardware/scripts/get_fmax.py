#!/usr/bin/env python3

import os
import argparse

CPU_CLOCK = 'cpu_clk_int'


def get_fmax(f, clock=CPU_CLOCK):
  """Returns (frequency of `clock` in MHz, design WNS in ns or None if the report has none)."""
  lines = f.read().splitlines()
  fmax = None
  wns = None
  for i, line in enumerate(lines):
    if line.startswith('| Design Timing Summary') and wns is None:
      # the column header row, a row of dashes, then the values
      for j in range(i + 1, len(lines) - 2):
        if lines[j].strip().startswith('WNS'):
          x = lines[j + 2].split()
          if x:
            wns = float(x[0])
          break
    elif line.startswith('| Clock Summary') and fmax is None:
      for l in lines[i + 1:]:
        x = l.split()
        if x and x[0] == clock:
          fmax = float(x[-1])
          break
  if fmax is None:
    raise ValueError(f"clock '{clock}' is not in the report's Clock Summary")
  return fmax, wns


if __name__ == '__main__':
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument('rpt', action='store', help='timing summary report')
  parser.add_argument('--clock', action='store', default=CPU_CLOCK, help='clock name (default: %(default)s)')

  args = parser.parse_args()
  if not os.path.isfile(args.rpt):
    print(args.rpt + ' not found')
    exit(1)

  with open(args.rpt) as f:
    fmax, wns = get_fmax(f, args.clock)
  print('Fmax (MHz): ' + str(fmax))
  print('WNS (ns): ' + str(wns))
  if wns is not None and wns < 0:
    print(f'ERROR: Negative slack. Timing violated. WNS(ns) = {wns}')
