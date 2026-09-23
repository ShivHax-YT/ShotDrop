#!/usr/bin/env python3
"""Shim: forwards to the shared MacFleet coord CLI."""
import runpy, sys
TARGET = '/Users/sharms18/Documents/Projects/MacFleet/fleet/coord.py'
sys.argv[0] = TARGET
runpy.run_path(TARGET, run_name="__main__")
