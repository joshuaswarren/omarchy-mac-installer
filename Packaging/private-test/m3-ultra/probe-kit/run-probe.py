#!/usr/bin/env python3
"""Run the Mac Studio (M3 Ultra) boot-loader probe from the second computer.

Usage: python3 run-probe.py [--power-gpu]

Waits up to two minutes for the Mac's boot loader to appear as a USB serial device, then runs the probe
once and writes ./probe-out-<time>/. SEND probe.txt AND SHA256SUMS ONLY. Never send the private folder.
"""
import glob
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
WAIT = 120


def find_device():
    found = sorted(glob.glob("/dev/cu.usbmodem*") + glob.glob("/dev/ttyACM*"))
    # the boot loader's proxy port is the first of its two ports (macOS names it ...P_01)
    for d in found:
        if "P_01" in d:
            return d
    return found[0] if found else None


def main():
    try:
        import construct  # noqa: F401
        import serial  # noqa: F401
    except ImportError:
        sys.exit("Missing Python modules. Run:  python3 -m pip install --user pyserial construct   then run this again.")
    dev = os.environ.get("M1N1DEVICE") or None
    t0 = time.time()
    while dev is None and time.time() - t0 < WAIT:
        dev = find_device()
        if dev is None:
            print("waiting for the boot loader on USB ...", flush=True)
            time.sleep(5)
    if dev is None:
        sys.exit("No device after 2 minutes. Try the next USB-C port on the Mac, or take a photo of its screen and stop.")
    print("using", dev)
    out = time.strftime("probe-out-%Y%m%d-%H%M%S")
    env = dict(os.environ, M1N1DEVICE=dev)
    args = [sys.executable, os.path.join(HERE, "proxyclient", "tools", "stage1_probe_t6032.py"), out]
    args += [a for a in sys.argv[1:] if a == "--power-gpu"]
    rc = subprocess.call(args, env=env)
    print(f"\nDone (exit {rc}). Send {out}/probe.txt and {out}/SHA256SUMS only. Do NOT send {out}/private.")
    sys.exit(rc)


if __name__ == "__main__":
    main()
