#!/usr/bin/env python3
"""Checkpoint 4 FOM

    FOM = 10^5 * sqrt(Fmax_CPU / (CPI * T_t2t * cost))

  Fmax_CPU  MHz, the CPU clock (cpu_clk_int) from the post-route timing summary
  CPI       geometric mean of the bdd, mmult, qsort and sha256 benchmarks' CPIs, run on the FPGA
            (get_cpi.py)
  T_t2t     ns, the median tick-to-trade the trading simulator reports for a round with your
            board (its "FPGA tag latency" median); give it with --t2t
  cost      the post-route utilization report, priced by get_cost.py

Run from anywhere. the reports are found relative to this script. Program the board first
(make program): the CPI run uses your leased board's UART.
"""

version = '2.0'

import argparse
import math
import os
import sys
import time
from pathlib import Path

from get_cost import get_cost, unknown_message
from get_fmax import get_fmax
from get_cpi import get_cpi
from run_fpga import default_port, DEFAULT_TIMEOUT_S

BUILD = Path(__file__).resolve().parent.parent / 'build'
REPORTS = {   # (utilization, timing summary)
    'impl': (BUILD / 'impl/post_route_utilization.rpt', BUILD / 'impl/post_route_timing_summary.rpt'),
    'synth': (BUILD / 'synth/post_synth_utilization.rpt', BUILD / 'synth/post_synth_timing_summary.rpt'),
}


def fom(fmax_mhz, cpi, t2t_ns, cost):
  return 1e5 * math.sqrt(fmax_mhz / (cpi * t2t_ns * cost))


def open_rpt(path):
  print('Using {} (last modified: {})'.format(path, time.ctime(os.path.getmtime(path))))
  return open(path)


def main():
  parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
  parser.add_argument('--t2t', action='store', type=float, required=True,
                      help='median tick-to-trade in ns, from the trading simulator')
  parser.add_argument('-s', '--synth', action='store_true',
                      help='estimate from the post-synthesis reports instead of the post-route ones')
  parser.add_argument('-i', '--impl', action='store_true', help='use the post-route reports (the default)')
  parser.add_argument('-u', '--urpt', action='store', help='utilization report (overrides -s/-i)')
  parser.add_argument('-t', '--trpt', action='store', help='timing summary report (overrides -s/-i)')
  parser.add_argument('-c', '--cost', action='store', type=int, help='override the cost')
  parser.add_argument('-f', '--fmax', action='store', type=float, help='override the CPU Fmax, in MHz')
  parser.add_argument('--cpi', action='store', type=float, help='override the CPI (skips the FPGA run)')
  parser.add_argument('--port_name', action='store', default=None,
                      help="serial port (default: your leased board's PMOD UART)")
  parser.add_argument('--com_name', action='store', default='COM11')
  parser.add_argument('--timeout', action='store', type=float, default=DEFAULT_TIMEOUT_S,
                      help='seconds each benchmark may run on the FPGA (default: %(default)s)')
  parser.add_argument('-o', '--output', action='store', default='fom.txt',
                      help="results file (default: %(default)s; '' for none)")
  args = parser.parse_args()
  if args.synth and args.impl:
    parser.error('give -s or -i, not both')

  print('fom version ' + version)
  urpt, trpt = REPORTS['synth' if args.synth else 'impl']
  urpt = Path(args.urpt) if args.urpt else urpt
  trpt = Path(args.trpt) if args.trpt else trpt

  errors = []     # printed as they happen, and repeated in the results file

  def error(msg):
    print(msg)
    errors.append(msg)

  def finish(results=''):
    if args.output:
      Path(args.output).write_text(''.join(e + '\n' for e in errors) + results)
      print('Results written to {}'.format(args.output))
    sys.exit(0 if results else 1)

  if args.cost is not None:
    cost = args.cost
  elif urpt.is_file():
    with open_rpt(urpt) as f:
      cost, unknown = get_cost(f)
    for ele in unknown:
      error(unknown_message(ele))
  else:
    error('ERROR: {} not found: run make impl, or give the cost with -c'.format(urpt))
    finish()

  if args.fmax is not None:
    fmax = args.fmax
  elif trpt.is_file():
    with open_rpt(trpt) as f:
      fmax, wns = get_fmax(f)
    if wns is not None and wns < 0:
      error('ERROR: Negative slack. Timing violated. WNS(ns) = {}'.format(wns))
  else:
    error('ERROR: {} not found: run make impl, or give the CPU Fmax with -f'.format(trpt))
    finish()

  if args.cpi is not None:
    cpi = args.cpi
  else:
    try:
      cpi = get_cpi(args.port_name or default_port(), args.com_name, args.timeout)
    except (FileNotFoundError, TimeoutError) as e:
      error('ERROR: CPI run failed: {}'.format(e))
      finish()

  bad = [(n, v) for n, v in (('cost', cost), ('Fmax', fmax), ('CPI', cpi), ('T_t2t', args.t2t)) if not v > 0]
  for name, value in bad:
    error('ERROR: {} must be positive, got {}'.format(name, value))
  if bad:
    finish()

  results = (
      '\n'
      'Fmax (MHz): {}\n'
      'CPI: {:.4f}\n'
      'T_t2t (ns): {}\n'
      'Cost: {}\n'
      '\n'
      'FOM: {:.2f}\n'
  ).format(fmax, cpi, args.t2t, cost, fom(fmax, cpi, args.t2t, cost))
  if args.synth and not (args.urpt or args.trpt):
    results += '(estimated from the post-synthesis reports)\n'
  print(results)
  finish(results)


if __name__ == '__main__':
  main()
