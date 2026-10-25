#!/usr/bin/env python3
"""Run the Mac Studio (M3 Ultra) boot-loader probe from the second computer.

Usage: python3 run-probe.py [--power-gpu]

Waits up to two minutes for the Mac's boot loader to appear as a USB serial device, then runs the probe
once and writes ./probe-out-<time>/. SEND probe.txt AND SHA256SUMS ONLY. Never send the private folder.

On a computer that has other USB serial devices plugged in, pick the Mac's port yourself:
set M1N1DEVICE=/dev/... (for example /dev/ttyACM0 or /dev/cu.usbmodem...01) before running.
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
    if rc == 0:
        print(f"\nDone. Send {out}/probe.txt and {out}/SHA256SUMS only. Do NOT send {out}/private.")
    else:
        print(f"\nFAILED (exit {rc}). Copy ALL the text above from this window and send it, with a photo of the Mac's screen.")
        if os.path.exists(os.path.join(out, "probe.txt")):
            print(f"Also send {out}/probe.txt (partial). Do NOT send {out}/private.")
        print("If this computer has other USB serial devices, set M1N1DEVICE=/dev/... to the Mac's port and run again.")
    sys.exit(rc)


if __name__ == "__main__":
    main()
