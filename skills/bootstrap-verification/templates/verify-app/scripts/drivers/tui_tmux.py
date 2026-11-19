#!/usr/bin/env python3
"""
tui_tmux.py: drive a terminal app (TUI, REPL, interactive CLI) inside a detached tmux
session: send keys, wait for text, capture the screen as evidence.

Usage:
  tui_tmux.py --cmd "./myapp --flag" --steps steps.json [--size 120x40] [--out DIR]
  tui_tmux.py --cmd "htop" --step '{"wait_for": "CPU"}' --step '{"capture": "start"}'

Steps (JSON list, run in order):
  {"wait_for": "regex", "timeout": 10}   wait until the screen matches
  {"send": "text"}                       type literal text (no Enter)
  {"keys": ["Enter"]}                    tmux key names: Enter, Escape, Tab, BSpace, Up,
                                         Down, Left, Right, C-c, C-x, M-x, F1, PageDown ...
  {"expect": "regex"}                    fail unless the screen matches now
  {"expect_not": "regex"}                fail if the screen matches now
  {"capture": "name"}                    save the screen to OUT/name.txt
  {"exited": true, "timeout": 5}         wait for the app to exit (optionally {"code": 0})
  {"sleep": 0.2}                         last resort; prefer wait_for

The final screen is always saved to OUT/final.txt, and on failure to OUT/failure.txt.
OUT defaults to $VERIFY_RUN_DIR (set by verify.py) or the current directory.
Exit code: 0 success, 1 a step failed, 2 usage/environment error.

Requires tmux (Linux, macOS, WSL). No Python packages.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid


SOCKET = "verify-" + uuid.uuid4().hex[:8]
EXIT_FILE = os.path.join(tempfile.gettempdir(), SOCKET + ".exit")


def tmux(*args, check=True):
    # A private tmux server (-L) inherits this process's environment and working
    # directory, and never touches the user's own tmux sessions.
    res = subprocess.run(["tmux", "-L", SOCKET] + list(args), capture_output=True, text=True)
    if check and res.returncode != 0:
        raise RuntimeError("tmux %s failed: %s" % (" ".join(args), res.stderr.strip()))
    return res


def screen(session):
    return tmux("capture-pane", "-p", "-t", session, "-J").stdout


def alive(session):
    """(running, exit_code). The wrapper writes the app's exit code to EXIT_FILE, which is
    more reliable than tmux's pane status for apps that exit quickly."""
    if os.path.exists(EXIT_FILE):
        with open(EXIT_FILE, "r", encoding="utf-8") as fh:
            text = fh.read().strip()
        if text.lstrip("-").isdigit():
            return False, int(text)
    return True, None


def save(out, name, text):
    path = os.path.join(out, name if name.endswith(".txt") else name + ".txt")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    return path


def run(args):
    if not shutil.which("tmux"):
        print("tui_tmux: tmux is not installed", file=sys.stderr)
        return 2
    steps = []
    if args.steps:
        with open(args.steps, "r", encoding="utf-8") as fh:
            steps = json.load(fh)
    steps += [json.loads(s) for s in args.step or []]
    out = args.out or os.environ.get("VERIFY_RUN_DIR") or "."
    os.makedirs(out, exist_ok=True)
    cols, rows = args.size.lower().split("x")
    session = "app"

    # Run the app, record its exit code, then keep the pane open (and its last screen
    # visible) until we kill the private server.
    wrapped = "%s\necho $? > '%s'\nexec sleep 2147483647" % (args.cmd, EXIT_FILE)
    tmux("new-session", "-d", "-s", session, "-x", cols, "-y", rows, wrapped)
    failed = None
    try:
        for i, step in enumerate(steps, 1):
            failed = do_step(session, step, out)
            label = json.dumps(step)
            if failed:
                print("  step %d FAIL %s: %s" % (i, label, failed))
                break
            print("  step %d ok   %s" % (i, label))
    except RuntimeError as exc:
        failed = str(exc)
    finally:
        try:
            final = screen(session)
        except RuntimeError:
            final = ""
        save(out, "final", final)
        if failed:
            save(out, "failure", final)
        if os.path.exists(EXIT_FILE):
            os.remove(EXIT_FILE)
        if not args.keep:
            tmux("kill-server", check=False)
        else:
            print("tui_tmux: session kept; attach with: tmux -L %s attach" % SOCKET)
    if failed:
        print("tui_tmux: FAILED: %s\n--- screen ---\n%s" % (failed, final.rstrip()))
        return 1
    print("tui_tmux: OK (%d steps)" % len(steps))
    return 0


def do_step(session, step, out):
    if "wait_for" in step:
        rx = re.compile(step["wait_for"], re.MULTILINE)
        deadline = time.time() + float(step.get("timeout", 10))
        while time.time() < deadline:
            if rx.search(screen(session)):
                return None
            running, code = alive(session)
            if not running:
                return "app exited (code %s) while waiting for /%s/" % (code, step["wait_for"])
            time.sleep(0.1)
        return "timed out waiting for /%s/" % step["wait_for"]
    if "send" in step:
        tmux("send-keys", "-t", session, "-l", step["send"])
        return None
    if "keys" in step:
        keys = step["keys"] if isinstance(step["keys"], list) else [step["keys"]]
        tmux("send-keys", "-t", session, *keys)
        return None
    if "expect" in step:
        return None if re.search(step["expect"], screen(session), re.MULTILINE) else \
            "screen does not match /%s/" % step["expect"]
    if "expect_not" in step:
        return "screen matches /%s/" % step["expect_not"] \
            if re.search(step["expect_not"], screen(session), re.MULTILINE) else None
    if "capture" in step:
        save(out, step["capture"], screen(session))
        return None
    if "exited" in step:
        deadline = time.time() + float(step.get("timeout", 5))
        while time.time() < deadline:
            running, code = alive(session)
            if not running:
                if "code" in step and code != step["code"]:
                    return "exited with %s (expected %s)" % (code, step["code"])
                return None
            time.sleep(0.1)
        return "app still running"
    if "sleep" in step:
        time.sleep(float(step["sleep"]))
        return None
    return "unknown step %s" % json.dumps(step)


def main():
    p = argparse.ArgumentParser(description="Drive a terminal app through tmux.")
    p.add_argument("--cmd", required=True, help="command line to run in the terminal")
    p.add_argument("--steps", help="JSON file with a list of steps")
    p.add_argument("--step", action="append", help="one JSON step (repeatable)")
    p.add_argument("--size", default="120x40", help="terminal COLSxROWS")
    p.add_argument("--out", help="evidence directory")
    p.add_argument("--keep", action="store_true", help="leave the tmux session running")
    return run(p.parse_args())


if __name__ == "__main__":
    sys.exit(main())
