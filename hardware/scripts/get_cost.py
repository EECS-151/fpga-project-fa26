#!/usr/bin/env python3

version = '1.3'

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
            'RAMD64E': 1713,
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
  """Returns (cost, primitives the price table doesn't know) from a utilization report."""
  print('get_cost version ' + version)
  cost = 0
  unknown = []
  lines = iter(f.read().splitlines())
  for line in lines:
    if "Ref Name" in line and "Used" in line and "Functional Category" in line:
      next(lines)                       # the +---+ under the header
      for line in lines:
        if line.startswith('+'):
          break
        x = line.split('|')
        ele = x[1].strip()
        cnt = int(x[2].strip())
        if ele in elements:
          cost += cnt * elements[ele]
        else:
          unknown.append(ele)
  return cost, unknown

def unknown_message(ele):
  return ele + ' is not a known element! Please report to TA.'

if __name__ == '__main__':
  parser = argparse.ArgumentParser()
  parser.add_argument('rpt', action='store', help='resource utilization report')
  parser.add_argument('-v', '--version', action='version', version='%(prog)s ' + version)

  args = parser.parse_args()
  if not os.path.isfile(args.rpt):
    print(args.rpt + ' not found')
    exit(1)

  with open(args.rpt) as f:
    cost, unknown = get_cost(f)
  for ele in unknown:
    print(unknown_message(ele))
  print('Cost: ' + str(cost))
