#!/usr/bin/env python3

version = '1.2'

import math
import os
import sys
import time
import argparse
from pathlib import Path

from get_cost import get_cost
from get_fmax import get_fmax
from run_coremark import run_zephyr_coremark

surpt = "build/synth/post_synth_utilization.rpt"
strpt = "build/synth/post_synth_timing_summary.rpt"
iurpt = "build/impl/post_place_utilization.rpt"
itrpt = "build/impl/post_route_timing_summary.rpt"

DEFAULT_HEX = Path(__file__).resolve().parent.parent.parent / "zephyr/zephyr/build/zephyr/zephyr.hex"


def open_file(fname):
  if os.path.isfile(fname):
    print('Using {} (last modified: {})'.format(fname, time.ctime(os.path.getmtime(fname))))
    return open(fname, 'r')
  else:
    print(fname + ' not found')
    return None

def open_rpts(urpt, trpt, fcost, ffmax):
  u = None
  if fcost is None:
    u = open_file(urpt)
  t = None
  if ffmax is None:
    t = open_file(trpt)
  return u, t

parser = argparse.ArgumentParser(
    description="FOM calculation program: by default, reads the newest set of reports for cost and fmax, runs CoreMark on the FPGA, and displays FOM. '-s' or '-i' forces use of reports in 'build/synth' or 'build/impl', respectively. You can manually specify reports with '-u' and '-t'. You can override cost, fmax, or coremarks with '-c', '-f', and '--coremarks', respectively.")

parser.add_argument('-s', '--synth', action='store_true', help='use synthesis reports')
parser.add_argument('-i', '--impl', action='store_true', help='use implementation reports')

parser.add_argument('-u', '--urpt', action='store', help='resource utilization report')
parser.add_argument('-t', '--trpt', action='store', help='timing summary report')

parser.add_argument('--port_name', action='store', default='/dev/ttyUSB0')
parser.add_argument('--com_name', action='store', default='COM11')
parser.add_argument(
    '--hex',
    action='store',
    default=str(DEFAULT_HEX),
    help='Zephyr .hex image for CoreMark (default: %(default)s)',
)

parser.add_argument('-c', '--cost', action='store', type=int)
parser.add_argument('-f', '--fmax', action='store', type=float, help='in MegaHertz, int or float')
parser.add_argument(
    '--coremarks',
    action='store',
    type=float,
    help='override CoreMark score (skip FPGA run)',
)

args = parser.parse_args()

if (args.urpt is None) != (args.trpt is None):
  print('both urpt and trpt must be specified when one of them are specified')
  exit()
if args.synth and args.impl:
  print('specify none or either of -s or -i')
  exit()

if not(args.urpt is None):
  u, t = open_rpts(args.urpt, args.trpt, args.cost, args.fmax)
elif args.synth:
  u, t = open_rpts(surpt, strpt, args.cost, args.fmax)
elif args.impl:
  u, t = open_rpts(iurpt, itrpt, args.cost, args.fmax)
elif os.path.isfile(surpt) and os.path.isfile(iurpt):
  if os.path.getmtime(surpt) > os.path.getmtime(iurpt):
    u, t = open_rpts(surpt, strpt, args.cost, args.fmax)
  else:
    u, t = open_rpts(iurpt, itrpt, args.cost, args.fmax)
elif os.path.isfile(surpt):
  u, t = open_rpts(surpt, strpt, args.cost, args.fmax)
elif os.path.isfile(iurpt):
  u, t = open_rpts(iurpt, itrpt, args.cost, args.fmax)
else:
  u, t = None, None

if u is None and args.cost is None:
  print('utilization report not found and cost not specified')
  exit()
elif args.cost is None:
  cost = get_cost(u)
else:
  cost = args.cost

if t is None and args.fmax is None:
  print('timing report not found and fmax not specified')
  exit()
elif args.fmax is None:
  fmax = get_fmax(t)
else:
  fmax = args.fmax

if args.coremarks is not None:
  coremarks = args.coremarks
else:
  result = run_zephyr_coremark(args.hex, args.port_name, args.com_name)
  if result.get('error'):
    print('CoreMark run failed')
    sys.exit(1)
  total_ticks = result['total_ticks']
  iterations = result['iterations']
  coremarks = iterations / (total_ticks / (fmax * 1e6))

coremarks_per_mhz = coremarks / fmax
fom = coremarks / math.sqrt(cost) * 100.0

print('')
print('Fmax: ' + str(fmax))
print('Coremarks: {:.4f}'.format(coremarks))
print('Coremarks/MHz: {:.4f}'.format(coremarks_per_mhz))
print('Cost: ' + str(cost))
print('')
print('FOM: {:.2f}'.format(fom))
