#!/usr/bin/env python3

version = '1.2'

import os
import argparse

elements = {'LUT6': 1713,
            'FDRE': 107,
            'LUT4': 429,
            'LUT5': 857,
            'LUT3': 429,
            'LUT2': 429,
            'CARRY4': 54,
            'CARRY8': 108,
            'RAMD32': 857,
            'RAMB36E2': 0,
            'RAMS32': 857,
            'RAMS64E': 1713,
            'FDSE': 107,
            'LUT1': 429,
            'MUXF7': 7,
            'MUXF8': 7,
            'OBUFT': 0,
            'IBUF': 0,
            'IBUFCTRL': 0,
            'BUFGCE': 0,
            'INBUF': 0,
            'DIFFINBUF': 0,
            'MMCME4_ADV': 0,
            'FDCE': 107,
            'FDPE': 107,
            'BUFG': 0,
            'SRL16E': 429,
            'SRLC16E': 429,
            'SRLC32E': 858,
            'PLLE2_ADV': 0,
            'OBUF': 0,
            'DSP48E2': 453_659,
            'BSCANE2': 0,
            'RAMB18E2': 0
            }

def get_cost(f):
  print('get_cost version ' + version)
  cost = 0
  for line in f:
    if "Ref Name" in line and "Used" in line and "Functional Category" in line:
      next(f)
      line = next(f)
      while not(line.startswith('+')):
        x = line.split('|')
        ele = x[1].strip()
        cnt = int(x[2].strip())
        if ele in elements:
          cst = cnt * elements[ele]
          cost += cst
        else:
          print(ele + ' is not a known element! Please report to TA.')
        line = next(f)
  return cost

if __name__ == '__main__':
  parser = argparse.ArgumentParser()
  parser.add_argument('rpt', action='store', help='resource utilization report')
  parser.add_argument('-v', '--version', action='version', version='%(prog)s ' + version)

  args = parser.parse_args()
  if os.path.isfile(args.rpt):
    f = open(args.rpt, 'r')
  else:
    print(args.rpt + ' not found')
    exit()

  print('Cost: ' + str(get_cost(f)))
