#!/usr/bin/env python3
"""
screenshot.py: capture the screen (or one window) on Linux, macOS or Windows, for
desktop-app evidence.

Usage:
  screenshot.py NAME                    full screen  -> OUT/NAME.png
  screenshot.py NAME --window "Title"   one window (Linux X11 via xdotool; macOS by app name)

OUT is $VERIFY_RUN_DIR (set by verify.py) or the current directory; override with --out.
Exit code 0 on success, 1 if no capture tool worked.

Tools tried, in order:
  Linux/X11:  import (ImageMagick), scrot, gnome-screenshot, xwd+convert
  Linux/Wayland: grim
  macOS: screencapture
  Windows: PowerShell + System.Drawing (built in)
"""
import argparse
import os
import shutil
import subprocess
import sys


def run(cmd, **kw):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=30, **kw).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def x11_window_id(title):
    if not shutil.which("xdotool"):
        return None
    res = subprocess.run(["xdotool", "search", "--name", title], capture_output=True, text=True)
    ids = res.stdout.split()
    return ids[-1] if ids else None


def capture(path, window=None):
    plat = sys.platform
    if plat.startswith("linux"):
        if os.environ.get("WAYLAND_DISPLAY") and shutil.which("grim") and not window:
            if run(["grim", path]):
                return True
        if os.environ.get("DISPLAY"):
            wid = x11_window_id(window) if window else None
            if window and not wid:
                print("screenshot: window %r not found (needs xdotool); capturing full screen"
                      % window, file=sys.stderr)
            if shutil.which("import") and run(["import", "-window", wid or "root", path]):
                return True
            if not wid and shutil.which("scrot") and run(["scrot", "-o", path]):
                return True
            if not wid and shutil.which("gnome-screenshot") and run(["gnome-screenshot", "-f", path]):
                return True
            if shutil.which("xwd") and shutil.which("convert"):
                xwd = path + ".xwd"
                ok = run(["xwd", "-root" if not wid else "-id", *([] if not wid else [wid]),
                          "-silent", "-out", xwd]) and run(["convert", xwd, path])
                if os.path.exists(xwd):
                    os.remove(xwd)
                if ok:
                    return True
        return False
    if plat == "darwin":
        if window:
            script = ('tell application "System Events" to get id of first window of '
                      '(first process whose name is "%s")' % window)
            res = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
            if res.returncode == 0 and res.stdout.strip().isdigit():
                return run(["screencapture", "-x", "-l", res.stdout.strip(), path])
        return run(["screencapture", "-x", path])
    if plat.startswith("win"):
        ps = (
            "Add-Type -AssemblyName System.Windows.Forms,System.Drawing;"
            "$b=[System.Windows.Forms.SystemInformation]::VirtualScreen;"
            "$bmp=New-Object System.Drawing.Bitmap $b.Width,$b.Height;"
            "$g=[System.Drawing.Graphics]::FromImage($bmp);"
            "$g.CopyFromScreen($b.Left,$b.Top,0,0,$bmp.Size);"
            "$bmp.Save('%s',[System.Drawing.Imaging.ImageFormat]::Png)" % path.replace("'", "''")
        )
        return run(["powershell", "-NoProfile", "-Command", ps])
    return False


def main():
    p = argparse.ArgumentParser(description="Cross-platform screenshot for evidence.")
    p.add_argument("name")
    p.add_argument("--window")
    p.add_argument("--out")
    args = p.parse_args()
    out = args.out or os.environ.get("VERIFY_RUN_DIR") or "."
    os.makedirs(out, exist_ok=True)
    path = os.path.abspath(os.path.join(out, args.name if args.name.endswith(".png") else args.name + ".png"))
    if capture(path, args.window) and os.path.exists(path):
        print("screenshot: %s" % path)
        return 0
    print("screenshot: no capture tool worked on this system (see script header)", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
