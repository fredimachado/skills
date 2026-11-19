#!/usr/bin/env python3
"""
verify.py: a reproducible, config-driven harness that lets an agent build, run and check
an application, and collect evidence that a change works.

Works for web apps, services/APIs, desktop apps, terminal UIs and CLIs: it starts the
processes a scenario needs, waits until they're ready, runs steps (shell commands, HTTP
checks, file and log checks, UI drivers), stores everything under .verify/runs/, and exits
non-zero if anything failed.

Config: verify.config.json next to this skill's SKILL.md (or pass --config).

Commands:
  verify.py doctor                    check required tools and config, and whether an
                                      instance left running by `up` is alive and current
  verify.py list                      list scenarios
  verify.py build                     run the build command
  verify.py run [SCENARIO ...]        run scenarios (default: smoke); --all, --build
  verify.py up [SERVICE ...]          start services in the background for exploration
  verify.py down                      stop services started with `up`
  verify.py last [SCENARIO]           show the latest run's summary
  verify.py compare SCENARIO          compare metrics of the last two runs of a scenario
  verify.py check-map                 check feature-map.md against code and scenarios
  verify.py audit-map                 list UI strings in the map/recipes missing from source
  verify.py stale-map                 list features whose code changed after their map entry

Placeholders usable in any string in the config:
  {root} repo root · {skill} skill dir · {run_dir} evidence dir of this run ·
  {python} current Python interpreter · {name} any key from "vars"

Requires Python 3.8+. No third-party packages.
"""
import argparse
import datetime as dt
import difflib
import glob
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

IS_WIN = os.name == "nt"
SKILL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_CONFIG = os.path.join(SKILL_DIR, "verify.config.json")
DEFAULT_MAP = os.path.join(SKILL_DIR, "feature-map.md")
DEFAULT_STEP_TIMEOUT = 120
ANSI_RX = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


# =============================================================== utilities

class VerifyError(Exception):
    pass


def log(msg):
    print(msg, flush=True)


def slug(text):
    return re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-")[:60] or "step"


def find_root(config_dir, cfg):
    if cfg.get("root"):
        return os.path.abspath(os.path.join(config_dir, cfg["root"]))
    try:
        res = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=config_dir,
                             capture_output=True, text=True, check=True)
        return os.path.abspath(res.stdout.strip())
    except (OSError, subprocess.CalledProcessError):
        return os.getcwd()


class Ctx:
    """Everything a step needs: paths, placeholder values, env, running services."""

    def __init__(self, cfg, config_path, update_golden=False):
        self.cfg = cfg
        self.config_path = config_path
        self.skill = os.path.dirname(os.path.abspath(config_path))
        self.root = find_root(self.skill, cfg)
        self.run_dir = None
        self.update_golden = update_golden
        self.services = {}
        self.xvfb = None
        self.env = dict(os.environ)
        self.cfg_env = {k: str(v) for k, v in (cfg.get("env") or {}).items()}

    def values(self):
        vals = {"root": self.root, "skill": self.skill, "python": sys.executable,
                "run_dir": self.run_dir or os.path.join(self.root, ".verify", "tmp")}
        for k, v in (self.cfg.get("vars") or {}).items():
            vals[k] = str(v)
        return vals

    def fmt(self, obj):
        """Substitute known {placeholders}; leave other braces (JSON, shell) untouched."""
        vals = self.values()

        def sub(s):
            for _ in range(3):  # allow vars that reference other placeholders
                new = re.sub(r"\{([A-Za-z_][\w.-]*)\}",
                             lambda m: vals.get(m.group(1), m.group(0)), s)
                if new == s:
                    break
                s = new
            return s

        if isinstance(obj, str):
            return sub(obj)
        if isinstance(obj, list):
            return [self.fmt(x) for x in obj]
        if isinstance(obj, dict):
            return {k: self.fmt(v) for k, v in obj.items()}
        return obj

    def path(self, p):
        p = self.fmt(p)
        return p if os.path.isabs(p) else os.path.join(self.root, p)

    def step_env(self, extra=None):
        env = dict(self.env)
        # Config env is formatted per step so it can use {run_dir} and friends.
        for k, v in self.cfg_env.items():
            env[k] = self.fmt(v)
        env["VERIFY_RUN_DIR"] = self.run_dir or ""
        env["VERIFY_ROOT"] = self.root
        env["VERIFY_SKILL_DIR"] = self.skill
        for k, v in (extra or {}).items():
            env[k] = self.fmt(str(v))
        return env


def to_cmd(cmd):
    """Strings run through the shell (pipes, &&); lists run directly."""
    if isinstance(cmd, list):
        return cmd, False
    return cmd, True


def kill_tree(proc, grace=5.0):
    if proc.poll() is not None:
        return
    try:
        if IS_WIN:
            subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                           capture_output=True)
        else:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            try:
                proc.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        pass
    try:
        proc.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        pass


def kill_pid_tree(pid):
    try:
        if IS_WIN:
            subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True)
        else:
            os.killpg(os.getpgid(pid), signal.SIGTERM)
            time.sleep(1)
            try:
                os.killpg(os.getpgid(pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
    except (ProcessLookupError, PermissionError, OSError):
        pass


def popen_kwargs():
    if IS_WIN:
        return {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP}
    return {"start_new_session": True}


def tail(path, n=30):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return "".join(fh.readlines()[-n:])
    except OSError:
        return ""


# =============================================================== headless display

def maybe_start_xvfb(ctx):
    """Linux desktop apps without a display: start one Xvfb shared by services and drivers."""
    setting = (ctx.cfg.get("display") or {}).get("xvfb", "never")
    if setting == "never" or not sys.platform.startswith("linux"):
        return
    if setting == "auto" and (ctx.env.get("DISPLAY") or ctx.env.get("WAYLAND_DISPLAY")):
        return
    if not shutil.which("Xvfb"):
        log("  ! display.xvfb is set but Xvfb is not installed; continuing without it")
        return
    num = 99
    while os.path.exists("/tmp/.X11-unix/X%d" % num) or os.path.exists("/tmp/.X%d-lock" % num):
        num += 1
    size = (ctx.cfg.get("display") or {}).get("size", "1920x1080x24")
    ctx.xvfb = subprocess.Popen(["Xvfb", ":%d" % num, "-screen", "0", size, "-nolisten", "tcp"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                **popen_kwargs())
    for _ in range(50):
        if os.path.exists("/tmp/.X11-unix/X%d" % num):
            break
        time.sleep(0.1)
    ctx.env["DISPLAY"] = ":%d" % num
    log("  display: started Xvfb on :%d" % num)


def stop_xvfb(ctx):
    if ctx.xvfb:
        kill_tree(ctx.xvfb, grace=2)
        ctx.xvfb = None


# =============================================================== readiness

def wait_ready(ctx, spec, proc=None, log_path=None, label="service"):
    spec = ctx.fmt(spec or {})
    timeout = float(spec.get("timeout", 60))
    deadline = time.time() + timeout
    if "delay" in spec and len(spec) <= 2:
        time.sleep(float(spec["delay"]))
        return
    while time.time() < deadline:
        if proc is not None and proc.poll() is not None:
            raise VerifyError("%s exited with code %s before becoming ready.\n--- log tail ---\n%s"
                              % (label, proc.returncode, tail(log_path) if log_path else ""))
        if probe(spec, log_path):
            return
        time.sleep(0.25)
    raise VerifyError("%s not ready after %ss (%s).\n--- log tail ---\n%s"
                      % (label, timeout, json.dumps(spec), tail(log_path) if log_path else ""))


def probe(spec, log_path):
    if "http" in spec:
        try:
            with urllib.request.urlopen(spec["http"], timeout=2) as resp:
                return resp.status < 500
        except urllib.error.HTTPError as exc:
            return exc.code < 500
        except (urllib.error.URLError, OSError, ValueError):
            return False
    if "port" in spec:
        host = spec.get("host", "127.0.0.1")
        try:
            with socket.create_connection((host, int(spec["port"])), timeout=1):
                return True
        except OSError:
            return False
    if "log" in spec:
        src = spec.get("log_file") or log_path
        if not src or not os.path.exists(src):
            return False
        with open(src, "r", encoding="utf-8", errors="replace") as fh:
            return re.search(spec["log"], fh.read()) is not None
    if "file" in spec:
        return os.path.exists(spec["file"])
    if "delay" in spec:
        return True
    raise VerifyError("Unknown readiness check: %s" % json.dumps(spec))


# =============================================================== services

def start_service(ctx, name, log_dir):
    svc = (ctx.cfg.get("services") or {}).get(name)
    if svc is None:
        raise VerifyError("Unknown service '%s'." % name)
    svc = ctx.fmt(svc)
    cmd, shell = to_cmd(svc["cmd"])
    cwd = ctx.path(svc.get("cwd", "."))
    os.makedirs(log_dir, exist_ok=True)
    log_path = os.path.join(log_dir, "service-%s.log" % slug(name))
    fh = open(log_path, "w", encoding="utf-8", errors="replace")
    log("  starting %s: %s" % (name, cmd if shell else " ".join(cmd)))
    proc = subprocess.Popen(cmd, shell=shell, cwd=cwd, env=ctx.step_env(svc.get("env")),
                            stdout=fh, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                            **popen_kwargs())
    ctx.services[name] = {"proc": proc, "log": log_path, "fh": fh, "started": time.time()}
    t0 = time.time()
    wait_ready(ctx, svc.get("ready", {"delay": 1}), proc, log_path, label=name)
    ms = int((time.time() - t0) * 1000)
    log("  %s ready in %d ms" % (name, ms))
    return ms


def stop_services(ctx):
    for name, s in list(ctx.services.items()):
        kill_tree(s["proc"])
        try:
            s["fh"].close()
        except OSError:
            pass
        ctx.services.pop(name, None)


# =============================================================== checks

def as_list(x):
    if x is None:
        return []
    return x if isinstance(x, list) else [x]


def text_checks(label, text, step, problems):
    for s in as_list(step.get(label + "_contains")):
        if s not in text:
            problems.append("%s does not contain %r" % (label, s))
    for s in as_list(step.get(label + "_not_contains")):
        if s in text:
            problems.append("%s unexpectedly contains %r" % (label, s))
    for rx in as_list(step.get(label + "_matches")):
        if not re.search(rx, text, re.MULTILINE):
            problems.append("%s does not match /%s/" % (label, rx))


def golden_check(ctx, step, stdout, base, problems):
    golden = step.get("stdout_golden")
    if not golden:
        return
    gpath = ctx.path(golden)
    actual = stdout.replace("\r\n", "\n")
    for rx, rep in (step.get("normalize") or {}).items():
        actual = re.sub(rx, rep, actual)
    if ctx.update_golden or not os.path.exists(gpath):
        os.makedirs(os.path.dirname(gpath) or ".", exist_ok=True)
        with open(gpath, "w", encoding="utf-8") as fh:
            fh.write(actual)
        log("    golden %s: %s" % ("updated" if ctx.update_golden else "created", golden))
        return
    with open(gpath, "r", encoding="utf-8") as fh:
        expected = fh.read().replace("\r\n", "\n")
    if expected != actual:
        diff = "".join(difflib.unified_diff(expected.splitlines(True), actual.splitlines(True),
                                            "golden", "actual"))
        with open(base + ".golden.diff", "w", encoding="utf-8") as fh:
            fh.write(diff)
        problems.append("stdout differs from golden %s (see %s.golden.diff)"
                        % (golden, os.path.basename(base)))


def exit_ok(code, expected):
    if expected is None:
        expected = 0
    if expected == "any":
        return True
    if expected == "nonzero":
        return code != 0
    return code in as_list(expected)


def step_run(ctx, step, base, result):
    cmd, shell = to_cmd(step["run"])
    timeout = float(step.get("timeout", DEFAULT_STEP_TIMEOUT))
    try:
        proc = subprocess.run(cmd, shell=shell, cwd=ctx.path(step.get("cwd", ".")),
                              env=ctx.step_env(step.get("env")), input=step.get("stdin"),
                              capture_output=True, text=True, timeout=timeout,
                              encoding="utf-8", errors="replace")
        out, err, code = proc.stdout, proc.stderr, proc.returncode
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout if isinstance(exc.stdout, str) else (exc.stdout or b"").decode("utf-8", "replace")
        err = exc.stderr if isinstance(exc.stderr, str) else (exc.stderr or b"").decode("utf-8", "replace")
        code = None
    # Strip terminal colour codes so checks and failure messages see plain text.
    out = ANSI_RX.sub("", out or "")
    err = ANSI_RX.sub("", err or "")
    with open(base + ".stdout.txt", "w", encoding="utf-8") as fh:
        fh.write(out or "")
    with open(base + ".stderr.txt", "w", encoding="utf-8") as fh:
        fh.write(err or "")
    problems = []
    if code is None:
        problems.append("timed out after %ss" % timeout)
    elif not exit_ok(code, step.get("exit")):
        problems.append("exit code %s (expected %s)" % (code, step.get("exit", 0)))
    text_checks("stdout", out or "", step, problems)
    text_checks("stderr", err or "", step, problems)
    golden_check(ctx, step, out or "", base, problems)
    result["exit_code"] = code
    result["evidence"] += [base + ".stdout.txt", base + ".stderr.txt"]
    if problems:
        tail_out = (err or out or "").strip()[-1500:]
        if tail_out:
            problems.append("output tail:\n" + tail_out)
    return problems


def json_get(data, dotted):
    cur = data
    for part in dotted.split("."):
        if isinstance(cur, list) and part.isdigit():
            idx = int(part)
            if idx >= len(cur):
                return KeyError
            cur = cur[idx]
        elif isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return KeyError
    return cur


def step_http(ctx, step, base, result):
    h = step["http"]
    method = h.get("method", "GET").upper()
    headers = dict(h.get("headers") or {})
    body = None
    if "json" in h:
        body = json.dumps(h["json"]).encode("utf-8")
        headers.setdefault("Content-Type", "application/json")
    elif "body" in h:
        body = h["body"].encode("utf-8")
    req = urllib.request.Request(h["url"], data=body, method=method, headers=headers)
    timeout = float(h.get("timeout", 30))
    status, text = None, ""
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = resp.status
            text = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        status = exc.code
        text = exc.read().decode("utf-8", "replace")
    except (urllib.error.URLError, OSError) as exc:
        return ["request failed: %s" % exc]
    with open(base + ".response.txt", "w", encoding="utf-8") as fh:
        fh.write("%s %s -> %s\n\n%s" % (method, h["url"], status, text))
    result["evidence"].append(base + ".response.txt")
    result["status"] = status
    problems = []
    if status not in as_list(h.get("status", [200, 201, 204])):
        problems.append("HTTP %s (expected %s)" % (status, h.get("status", "2xx")))
    for s in as_list(h.get("contains")):
        if s not in text:
            problems.append("body does not contain %r" % s)
    for s in as_list(h.get("not_contains")):
        if s in text:
            problems.append("body unexpectedly contains %r" % s)
    if h.get("json_equals"):
        try:
            data = json.loads(text)
        except ValueError:
            return problems + ["body is not JSON"]
        for path, expected in h["json_equals"].items():
            got = json_get(data, path)
            if got is KeyError:
                problems.append("JSON path %s missing" % path)
            elif got != expected:
                problems.append("JSON %s = %r (expected %r)" % (path, got, expected))
    return problems


def step_file(ctx, step, base, result):
    f = step["file"]
    path = ctx.path(f["path"])
    if not os.path.exists(path):
        return ["file %s does not exist" % f["path"]]
    result["evidence"].append(path)
    problems = []
    if f.get("min_bytes") and os.path.getsize(path) < int(f["min_bytes"]):
        problems.append("file %s smaller than %s bytes" % (f["path"], f["min_bytes"]))
    if any(k in f for k in ("contains", "not_contains", "matches")):
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        for s in as_list(f.get("contains")):
            if s not in text:
                problems.append("file does not contain %r" % s)
        for s in as_list(f.get("not_contains")):
            if s in text:
                problems.append("file unexpectedly contains %r" % s)
        for rx in as_list(f.get("matches")):
            if not re.search(rx, text, re.MULTILINE):
                problems.append("file does not match /%s/" % rx)
    return problems


def step_log(ctx, step, base, result):
    lg = step["log"]
    svc = ctx.services.get(lg["service"])
    if not svc:
        return ["service %s is not running in this scenario" % lg["service"]]
    svc["fh"].flush()
    with open(svc["log"], "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    problems = []
    for s in as_list(lg.get("contains")):
        if s not in text:
            problems.append("%s log does not contain %r" % (lg["service"], s))
    for s in as_list(lg.get("not_contains")):
        if s in text:
            problems.append("%s log contains %r" % (lg["service"], s))
    for rx in as_list(lg.get("matches")):
        if not re.search(rx, text, re.MULTILINE):
            problems.append("%s log does not match /%s/" % (lg["service"], rx))
    for rx in as_list(lg.get("not_matches")):
        m = re.search(rx, text, re.MULTILINE)
        if m:
            problems.append("%s log matches /%s/: %r" % (lg["service"], rx, m.group(0)[:200]))
    return problems


def step_wait(ctx, step, base, result):
    spec = dict(step["wait"])
    log_path = None
    if "service" in spec:
        svc = ctx.services.get(spec.pop("service"))
        log_path = svc["log"] if svc else None
    try:
        wait_ready(ctx, spec, None, log_path, label="wait")
    except VerifyError as exc:
        return [str(exc)]
    return []


STEP_TYPES = {"run": step_run, "http": step_http, "file": step_file, "log": step_log,
              "wait": step_wait}


def run_step(ctx, idx, raw):
    step = ctx.fmt(raw)
    kind = next((k for k in STEP_TYPES if k in step), None)
    name = step.get("name") or (kind or "step")
    base = os.path.join(ctx.run_dir, "step-%02d-%s" % (idx, slug(name)))
    result = {"index": idx, "name": name, "type": kind, "evidence": []}
    if kind is None:
        result.update(ok=False, problems=["no known step type (%s)" % ", ".join(STEP_TYPES)])
        return result
    t0 = time.time()
    try:
        problems = STEP_TYPES[kind](ctx, step, base, result)
    except VerifyError as exc:
        problems = [str(exc)]
    except Exception as exc:  # report harness bugs as step failures, keep the run going
        problems = ["harness error: %r" % exc]
    ms = int((time.time() - t0) * 1000)
    result["duration_ms"] = ms
    if step.get("max_ms") is not None and ms > float(step["max_ms"]):
        problems.append("took %d ms (budget %s ms)" % (ms, step["max_ms"]))
    if step.get("metric"):
        result["metric"] = step["metric"]
    result["ok"] = not problems
    result["problems"] = problems
    return result


# =============================================================== scenarios

def collect_metrics(ctx, steps, startup):
    metrics = {}
    for name, ms in startup.items():
        metrics["startup_ms.%s" % name] = ms
    for s in steps:
        if s.get("metric"):
            metrics[s["metric"]] = s.get("duration_ms")
    mdir = os.path.join(ctx.run_dir, "metrics")
    if os.path.isdir(mdir):
        for f in sorted(os.listdir(mdir)):
            if f.endswith(".json"):
                try:
                    with open(os.path.join(mdir, f), "r", encoding="utf-8") as fh:
                        data = json.load(fh)
                    for k, v in data.items():
                        if isinstance(v, (int, float)):
                            metrics[k] = v
                except (OSError, ValueError):
                    pass
    return metrics


def check_budgets(budgets, metrics):
    problems = []
    for name, b in (budgets or {}).items():
        if name not in metrics:
            problems.append("budget metric %s was not produced" % name)
            continue
        v = metrics[name]
        if "max" in b and v > b["max"]:
            problems.append("%s = %s exceeds max %s" % (name, v, b["max"]))
        if "min" in b and v < b["min"]:
            problems.append("%s = %s below min %s" % (name, v, b["min"]))
    return problems


def run_scenario(ctx, name):
    scenarios = ctx.cfg.get("scenarios") or {}
    if name not in scenarios:
        raise VerifyError("Unknown scenario '%s'. Known: %s" % (name, ", ".join(scenarios)))
    sc = scenarios[name]
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    ctx.run_dir = os.path.join(ctx.root, ".verify", "runs", "%s-%s" % (stamp, slug(name)))
    os.makedirs(ctx.run_dir, exist_ok=True)
    log("\n== scenario %s: %s" % (name, sc.get("description", "")))
    log("   evidence: %s" % os.path.relpath(ctx.run_dir, ctx.root))

    started = time.time()
    results, setup_problems, startup = [], [], {}
    try:
        left_up = (up_state(ctx) or {}).get("services") or {}
        clash = [n for n in sc.get("needs", []) if n in left_up and pid_alive(left_up[n]["pid"])]
        if clash:
            raise VerifyError("%s already running from `verify.py up`. The scenario would start "
                              "a second copy and could end up checking the old one. Run "
                              "`verify.py down` first." % ", ".join(clash))
        maybe_start_xvfb(ctx)
        for svc in sc.get("needs", []):
            startup[svc] = start_service(ctx, svc, ctx.run_dir)
        stopped = False
        for i, raw in enumerate(sc.get("steps", []), 1):
            if stopped and not raw.get("always"):
                continue
            r = run_step(ctx, i, raw)
            results.append(r)
            mark = "PASS" if r["ok"] else "FAIL"
            log("  [%s] %s (%d ms)" % (mark, r["name"], r.get("duration_ms", 0)))
            for p in r["problems"]:
                log("        - " + p.replace("\n", "\n          "))
            if not r["ok"] and not raw.get("continue_on_fail") and not stopped:
                stopped = True
                later = sc.get("steps", [])[i:]
                skipped = sum(1 for st in later if not st.get("always"))
                if skipped:
                    log("  (stopping: %d later step(s) skipped; teardown steps still run)" % skipped)
    except VerifyError as exc:
        setup_problems.append(str(exc))
        log("  [FAIL] setup: " + str(exc).replace("\n", "\n         "))
    finally:
        stop_services(ctx)
        stop_xvfb(ctx)

    metrics = collect_metrics(ctx, results, startup)
    budget_problems = check_budgets(sc.get("budgets"), metrics)
    for p in budget_problems:
        log("  [FAIL] budget: " + p)
    ok = (not setup_problems and not budget_problems
          and all(r["ok"] for r in results)
          and len(results) == len(sc.get("steps", [])))  # skipped steps mean failure
    summary = {
        "scenario": name, "description": sc.get("description", ""),
        "features": sc.get("features", []), "ok": ok,
        "started": dt.datetime.fromtimestamp(started).isoformat(timespec="seconds"),
        "duration_ms": int((time.time() - started) * 1000),
        "setup_problems": setup_problems, "budget_problems": budget_problems,
        "metrics": metrics, "steps": results, "git": git_info(ctx.root),
    }
    with open(os.path.join(ctx.run_dir, "summary.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2)
    with open(os.path.join(ctx.run_dir, "summary.md"), "w", encoding="utf-8") as fh:
        fh.write(summary_md(ctx, summary))
    log("== %s: %s" % (name, "PASSED" if ok else "FAILED"))
    return summary


def git_info(root):
    try:
        rev = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=root,
                             capture_output=True, text=True).stdout.strip()
        dirty = subprocess.run(["git", "status", "--porcelain"], cwd=root,
                               capture_output=True, text=True).stdout.strip() != ""
        return {"rev": rev, "dirty": dirty}
    except OSError:
        return {}


def summary_md(ctx, s):
    lines = ["### Verification: `%s` %s" % (s["scenario"], "✅ passed" if s["ok"] else "❌ failed"), ""]
    if s["description"]:
        lines += [s["description"], ""]
    g = s.get("git") or {}
    lines.append("Commit `%s`%s · %s · %d ms" % (g.get("rev", "?"), " (uncommitted changes)"
                                                 if g.get("dirty") else "", s["started"],
                                                 s["duration_ms"]))
    lines += ["", "| # | Step | Result | Time |", "|---|---|---|---:|"]
    for r in s["steps"]:
        lines.append("| %d | %s | %s | %s ms |" % (r["index"], r["name"],
                                                   "pass" if r["ok"] else "**fail**",
                                                   r.get("duration_ms", "?")))
    problems = s["setup_problems"] + s["budget_problems"] + [
        "%s: %s" % (r["name"], p.splitlines()[0]) for r in s["steps"] for p in r["problems"]]
    if problems:
        lines += ["", "**Problems**", ""] + ["- " + p for p in problems]
    if s["metrics"]:
        lines += ["", "**Metrics**", ""] + ["- %s: %s" % kv for kv in sorted(s["metrics"].items())]
    lines += ["", "Evidence: `%s`" % os.path.relpath(ctx.run_dir, ctx.root), ""]
    return "\n".join(lines)


# =============================================================== commands

def cmd_doctor(ctx, args):
    ok = True
    log("config: %s" % ctx.config_path)
    log("root:   %s" % ctx.root)
    for tool in ctx.cfg.get("requires", []):
        found = shutil.which(tool)
        log("  %-16s %s" % (tool, found or "MISSING"))
        ok = ok and bool(found)
    for name in (ctx.cfg.get("services") or {}):
        log("  service %-8s %s" % (name, ctx.fmt(ctx.cfg["services"][name]["cmd"])))
    scen = ctx.cfg.get("scenarios") or {}
    if "smoke" not in scen:
        log("  ! no 'smoke' scenario; `verify.py run` with no arguments will fail")
        ok = False
    for name, sc in scen.items():
        for svc in sc.get("needs", []):
            if svc not in (ctx.cfg.get("services") or {}):
                log("  ! scenario %s needs unknown service %s" % (name, svc))
                ok = False
    if os.path.exists(DEFAULT_MAP) or args.map:
        log("feature map: %s" % (args.map or DEFAULT_MAP))
    state = up_state(ctx)
    if state:
        log("instance from `up` (started %s at commit %s):"
            % (state.get("started", "?"), (state.get("git") or {}).get("rev", "?")))
        problems, notes = up_problems(ctx, state)
        for p in problems:
            log("  ! " + p)
        for n in notes:
            log("  ~ " + n)
        if problems:
            log("  ! restart it before trusting what it shows: verify.py down, then up")
            ok = False
        elif not notes:
            log("  alive, and the code hasn't changed since it started")
    log("doctor: %s" % ("OK" if ok else "problems found"))
    return 0 if ok else 1


def cmd_list(ctx, args):
    for name, sc in (ctx.cfg.get("scenarios") or {}).items():
        feats = ", ".join(sc.get("features", []))
        log("%-24s %s%s" % (name, sc.get("description", ""), ("  [features: %s]" % feats) if feats else ""))
    return 0


def cmd_build(ctx, args):
    build = ctx.cfg.get("build")
    if not build:
        log("no build command configured")
        return 0
    cmd, shell = to_cmd(ctx.fmt(build))
    log("build: %s" % (cmd if shell else " ".join(cmd)))
    rc = subprocess.run(cmd, shell=shell, cwd=ctx.root, env=ctx.step_env()).returncode
    log("build: %s" % ("OK" if rc == 0 else "FAILED (exit %d)" % rc))
    return rc


def cmd_run(ctx, args):
    if args.build and cmd_build(ctx, args) != 0:
        return 1
    names = list((ctx.cfg.get("scenarios") or {}).keys()) if args.all else (args.scenarios or ["smoke"])
    summaries = []
    for n in names:
        try:
            summaries.append(run_scenario(ctx, n))
        except VerifyError as exc:
            log("error: %s" % exc)
            return 2
    failed = [s["scenario"] for s in summaries if not s["ok"]]
    if len(summaries) > 1:
        log("\n%d scenario(s): %d passed, %d failed%s" % (
            len(summaries), len(summaries) - len(failed), len(failed),
            (" (%s)" % ", ".join(failed)) if failed else ""))
    return 1 if failed else 0


def pids_file(ctx):
    return os.path.join(ctx.root, ".verify", "running.json")


def pid_alive(pid):
    if IS_WIN:  # os.kill(pid, 0) would terminate the process on Windows
        import ctypes
        k32 = ctypes.windll.kernel32
        k32.OpenProcess.restype = ctypes.c_void_p
        handle = k32.OpenProcess(0x1000, False, int(pid))  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return False
        try:
            code = ctypes.c_ulong()
            ok = k32.GetExitCodeProcess(ctypes.c_void_p(handle), ctypes.byref(code))
            return bool(ok) and code.value == 259  # STILL_ACTIVE
        finally:
            k32.CloseHandle(ctypes.c_void_p(handle))
    try:
        os.kill(int(pid), 0)
        return True
    except PermissionError:
        return True
    except OSError:
        return False


def up_state(ctx):
    """What `up` recorded about the instance it left running, or None."""
    try:
        with open(pids_file(ctx), "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def changed_since(root, ts):
    """Uncommitted files (modified or untracked) written after `ts`."""
    try:
        res = subprocess.run(["git", "ls-files", "-z", "-m", "-o", "--exclude-standard"],
                             cwd=root, capture_output=True)
    except OSError:
        return []
    changed = []
    for rel in sorted(set(res.stdout.decode("utf-8", "replace").split("\0"))):
        if not rel or rel.startswith(".verify/"):
            continue
        try:
            if os.path.getmtime(os.path.join(root, rel)) > ts:
                changed.append(rel)
        except OSError:
            pass
    return changed


def up_problems(ctx, state):
    """Reasons the instance left by `up` isn't worth driving, plus softer notes."""
    problems, notes = [], []
    for name, s in (state.get("services") or {}).items():
        if not pid_alive(s["pid"]):
            problems.append("service %s (pid %s) is no longer running" % (name, s["pid"]))
    then, now = state.get("git") or {}, git_info(ctx.root)
    if then.get("rev") and now.get("rev") and then["rev"] != now["rev"]:
        problems.append("it was started at commit %s; the tree is now at %s"
                        % (then["rev"], now["rev"]))
    if state.get("started_ts"):
        changed = changed_since(ctx.root, state["started_ts"])
        if changed:
            notes.append("%d file(s) changed since it started (e.g. %s); unless the app "
                         "hot-reloads, it is running old code" % (len(changed), changed[0]))
    return problems, notes


def cmd_up(ctx, args):
    names = args.services or list((ctx.cfg.get("services") or {}).keys())
    ctx.run_dir = os.path.join(ctx.root, ".verify", "up")
    os.makedirs(ctx.run_dir, exist_ok=True)
    maybe_start_xvfb(ctx)
    state = {"services": {}, "xvfb": ctx.xvfb.pid if ctx.xvfb else None,
             "display": ctx.env.get("DISPLAY"), "git": git_info(ctx.root),
             "started": dt.datetime.now().isoformat(timespec="seconds"),
             "started_ts": time.time()}
    try:
        for n in names:
            start_service(ctx, n, ctx.run_dir)
            s = ctx.services[n]
            state["services"][n] = {"pid": s["proc"].pid, "log": s["log"]}
    except VerifyError as exc:
        log("error: %s" % exc)
        stop_services(ctx)
        stop_xvfb(ctx)
        return 1
    with open(pids_file(ctx), "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2)
    log("running in background; logs in %s. Stop with: verify.py down"
        % os.path.relpath(ctx.run_dir, ctx.root))
    if state["display"] and ctx.xvfb:
        log("headless display: DISPLAY=%s" % state["display"])
    return 0  # processes live on in their own sessions


def cmd_down(ctx, args):
    path = pids_file(ctx)
    if not os.path.exists(path):
        log("nothing running (no %s)" % os.path.relpath(path, ctx.root))
        return 0
    with open(path, "r", encoding="utf-8") as fh:
        state = json.load(fh)
    for name, s in state.get("services", {}).items():
        kill_pid_tree(s["pid"])
        log("stopped %s (pid %s)" % (name, s["pid"]))
    if state.get("xvfb"):
        kill_pid_tree(state["xvfb"])
    os.remove(path)
    return 0


def runs_for(ctx, scenario=None):
    pattern = os.path.join(ctx.root, ".verify", "runs", "*" + (("-" + slug(scenario)) if scenario else ""))
    runs = []
    for d in sorted(glob.glob(pattern)):
        sfile = os.path.join(d, "summary.json")
        if os.path.exists(sfile):
            with open(sfile, "r", encoding="utf-8") as fh:
                s = json.load(fh)
            if scenario is None or s.get("scenario") == scenario:
                runs.append((d, s))
    return runs


def cmd_last(ctx, args):
    runs = runs_for(ctx, args.scenario)
    if not runs:
        log("no runs yet")
        return 1
    d, _ = runs[-1]
    with open(os.path.join(d, "summary.md"), "r", encoding="utf-8") as fh:
        log(fh.read())
    return 0


def cmd_compare(ctx, args):
    runs = runs_for(ctx, args.scenario)
    if len(runs) < 2:
        log("need at least two runs of %s to compare" % args.scenario)
        return 1
    (_, a), (_, b) = runs[-2], runs[-1]
    keys = sorted(set(a.get("metrics", {})) | set(b.get("metrics", {})))
    log("%-40s %12s %12s %10s" % ("metric", a["started"][-8:], b["started"][-8:], "change"))
    for k in keys:
        va, vb = a["metrics"].get(k), b["metrics"].get(k)
        if isinstance(va, (int, float)) and isinstance(vb, (int, float)) and va:
            change = "%+.1f%%" % ((vb - va) * 100.0 / va)
        else:
            change = ""
        log("%-40s %12s %12s %10s" % (k, va, vb, change))
    return 0


# --------------------------------------------------------------- feature map

def parse_feature_map(path):
    features, cur = [], None
    with open(path, "r", encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if line.startswith("## "):
                cur = {"title": line[3:].strip(), "fields": {}, "line": lineno}
                features.append(cur)
                continue
            m = re.match(r"^\s*[-*]\s*([A-Za-z_][\w-]*)\s*:\s*(.*)$", line)
            if cur is not None and m:
                cur["fields"][m.group(1).lower()] = m.group(2).strip()
    return features


def split_list(value):
    return [v.strip().strip("`") for v in re.split(r"[,;]", value or "") if v.strip().strip("`")]


def cmd_check_map(ctx, args):
    path = args.map or DEFAULT_MAP
    if not os.path.exists(path):
        log("no feature map at %s" % path)
        return 1
    features = parse_feature_map(path)
    scenarios = ctx.cfg.get("scenarios") or {}
    # Fields holding repo paths that must exist (and that count for map_coverage).
    path_fields = ctx.cfg.get("map_path_fields", ["code"])
    # Fields whose paths are relative to the map file itself (e.g. per-feature docs).
    rel_fields = set(ctx.cfg.get("map_relative_fields", []))
    map_dir = os.path.dirname(os.path.abspath(path))
    errors, warnings = [], []
    ids = {}
    for f in features:
        fid = f["fields"].get("id")
        if not fid:
            errors.append("feature '%s' has no id" % f["title"])
            continue
        if fid in ids:
            errors.append("duplicate feature id %s" % fid)
        ids[fid] = f
        for field in path_fields:
            for p in split_list(f["fields"].get(field)):
                if not glob.glob(os.path.join(map_dir if field in rel_fields else ctx.root, p),
                                 recursive=True):
                    errors.append("%s: %s path not found: %s" % (fid, field, p))
        verify = split_list(f["fields"].get("verify"))
        if not verify:
            warnings.append("%s: no verify scenario" % fid)
        for sc in verify:
            if sc not in scenarios:
                errors.append("%s: unknown scenario %s" % (fid, sc))
    for name, sc in scenarios.items():
        for fid in sc.get("features", []):
            if fid not in ids:
                errors.append("scenario %s references unknown feature %s" % (name, fid))
    # optional coverage: every directory matching these globs should belong to a feature
    covered = []
    for f in ids.values():
        for field in path_fields:
            for p in split_list(f["fields"].get(field)):
                full = os.path.join(map_dir if field in rel_fields else ctx.root, p)
                covered += [os.path.normpath(m) for m in (glob.glob(full, recursive=True) or [full])]
    for pattern in ctx.cfg.get("map_coverage", []):
        for d in sorted(glob.glob(os.path.join(ctx.root, pattern))):
            nd = os.path.normpath(d)
            if not any(nd == c or nd.startswith(c + os.sep) or c.startswith(nd + os.sep)
                       for c in covered):
                warnings.append("not in feature map: %s" % os.path.relpath(d, ctx.root))
    for e in errors:
        log("error: " + e)
    for w in warnings:
        log("warn:  " + w)
    log("check-map: %d feature(s), %d error(s), %d warning(s)" % (len(ids), len(errors), len(warnings)))
    return 1 if errors else 0


# --------------------------------------------------------------- handle audit

CMD_PREFIX = re.compile(r"^(?:[\w./-]*(?:verify\.py|control-\w+|\.mjs|\.py)\b|node |npm |npx |python|py |git |cd |"
                        r"(?:browser )?(?:assert[\w-]*|click|fill|goto|press|select) )")
ENTITIES = {"&apos;": "'", "&#39;": "'", "&quot;": '"', "&amp;": "&", "&rsquo;": "'", "&lsquo;": "'",
            "&ldquo;": '"', "&rdquo;": '"', "&nbsp;": " ", "\u2019": "'", "\u2018": "'",
            "\u201c": '"', "\u201d": '"', "\u00a0": " "}


def runtime_templates(corpus):
    """Regexes for strings built at runtime: `Remove ${name}` and JSX like >{a} vs {b}<."""
    pieces = re.findall(r"`([^`]*\$\{[^`]*)`", corpus)
    pieces += [p for p in re.findall(r">([^<>]*\{[^<>]*)<", corpus) if re.search(r"[A-Za-z]{2}", p)]
    out = []
    for piece in pieces:
        parts = re.split(r"\$?\{[^{}]*\}", piece)
        if not any(p.strip() for p in parts):
            continue  # pure placeholder, would match anything
        try:
            out.append(re.compile(r"\s*" + r".+?".join(re.escape(p.strip()) for p in parts) + r"\s*\Z"))
        except re.error:
            pass
    return out


def normalize_text(text):
    for k, v in ENTITIES.items():
        text = text.replace(k, v)
    return " ".join(text.split())
ARG_RX = re.compile(r'--(?:name|text|label|value)\s+(?:"([^"]+)"|(\S+))')


def ui_handles(text):
    """Strings in a map/recipe that look like UI copy or accessible names.

    Takes --name/--text values from command examples, plus inline `code` spans that read
    like UI text (capital letter or a space), and drops paths, code, ids and markup.
    """
    out = set()
    for span in re.findall(r"`([^`\n]+)`", text):
        span = span.strip()
        if CMD_PREFIX.match(span):
            out.update(a or b for a, b in ARG_RX.findall(span))
            continue
        if not (2 <= len(span) <= 80) or not re.search(r"[A-Z ]", span):
            continue
        if re.search(r"[/\\{}<>=()\[\]|]|^\.|\w\.\w|^[A-Z_-]+$|:\s*$|^[a-z]\w*:|^\d", span):
            continue  # paths, code, markup, API names, constants, dates/numbers
        out.add(span)
    return {h for h in out if h and not h.startswith("-")}


def cmd_audit_map(ctx, args):
    """Advisory: UI strings quoted in the map/recipes that no longer appear in the source.

    Recipes drift silently when copy or labels change. This lists every `backticked` or
    --name/--text "quoted" handle in the map and recipe files that can't be found in the
    configured source files. Dynamic strings (built at runtime) show up too, so review the
    list rather than treating it as errors.
    """
    path = args.map or DEFAULT_MAP
    if not os.path.exists(path):
        log("no feature map at %s" % path)
        return 1
    sources = ctx.cfg.get("map_handle_sources")
    if not sources:
        log("set \"map_handle_sources\" (globs of UI source files) in the config to use audit-map")
        return 2
    corpus = []
    for pattern in sources:
        for f in glob.glob(os.path.join(ctx.root, pattern), recursive=True):
            if any(x in f for x in (".test.", ".spec.", "__tests__")):
                continue
            try:
                with open(f, "r", encoding="utf-8", errors="replace") as fh:
                    corpus.append(fh.read())
            except OSError:
                pass
    corpus = normalize_text("\n".join(corpus))
    # Test data and runtime-built strings (player names, "{a} vs {b}") that are expected
    # to be absent from the source.
    ignore = [re.compile(rx) for rx in ctx.cfg.get("map_handle_ignore", [])]
    templates = runtime_templates(corpus)
    map_dir = os.path.dirname(os.path.abspath(path))
    docs = [path]
    rel_fields = set(ctx.cfg.get("map_relative_fields", []))
    for f in parse_feature_map(path):
        for field in rel_fields:
            docs += [os.path.join(map_dir, p) for p in split_list(f["fields"].get(field))]
    total = 0
    for doc in docs:
        if not os.path.exists(doc):
            continue
        with open(doc, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        missing = sorted(h for h in ui_handles(text)
                         if normalize_text(h) not in corpus
                         and not any(rx.search(h) for rx in ignore)
                         and not any(t.match(normalize_text(h)) for t in templates))
        if missing:
            total += len(missing)
            log("%s:" % os.path.relpath(doc, ctx.root))
            for h in missing:
                log("  - %s" % h)
    log("audit-map: %d handle(s) not found in source (stale copy, or built at runtime: "
        "fix the recipe, or add a map_handle_ignore pattern)" % total)
    return 1 if (total and args.strict) else 0


# --------------------------------------------------------------- map age

def git_out(root, *args):
    try:
        res = subprocess.run(["git"] + list(args), cwd=root, capture_output=True)
    except OSError:
        return None
    return res.stdout.decode("utf-8", "replace") if res.returncode == 0 else None


def commits_after(root, paths, since):
    """Commits touching `paths` that are newer than `since`, newest first: (time, hash, subject)."""
    found = {}
    specs = [":(literal)" + os.path.relpath(p, root).replace(os.sep, "/") for p in paths]
    for i in range(0, len(specs), 100):
        out = git_out(root, "log", "-n", "200", "--format=%ct%x09%h%x09%s", "--", *specs[i:i + 100])
        for row in (out or "").splitlines():
            ts, rev, subject = (row.split("\t", 2) + ["", ""])[:3]
            if ts.isdigit() and int(ts) > since:
                found[rev] = (int(ts), rev, subject)
    return sorted(found.values(), reverse=True)


def cmd_stale_map(ctx, args):
    """Advisory: features whose code has commits newer than the last edit to their map entry.

    check-map and audit-map can't tell when an entry is well-formed but no longer describes
    what the code does. This narrows "re-read every feature" down to the entries that were
    left alone while their code moved on. A hint, not a verdict: a refactoring flags an
    entry that is still accurate. Editing the entry (its `reviewed:` date, say) clears it.
    """
    path = args.map or DEFAULT_MAP
    if not os.path.exists(path):
        log("no feature map at %s" % path)
        return 1
    blame = git_out(ctx.root, "blame", "--line-porcelain", "--", os.path.abspath(path))
    if blame is None:
        log("stale-map: needs the feature map committed in a git repo; nothing to compare")
        return 0
    # One entry per line of the map; uncommitted lines carry the current time.
    line_times = [int(t) for t in re.findall(r"^committer-time (\d+)$", blame, re.MULTILINE)]
    features = parse_feature_map(path)
    path_fields = ctx.cfg.get("map_path_fields", ["code"])
    rel_fields = set(ctx.cfg.get("map_relative_fields", []))
    map_dir = os.path.dirname(os.path.abspath(path))
    stale = []
    for i, f in enumerate(features):
        end = features[i + 1]["line"] - 1 if i + 1 < len(features) else len(line_times)
        edited = max(line_times[f["line"] - 1:end] or [0])
        code = []
        for field in path_fields:
            for p in split_list(f["fields"].get(field)):
                hits = glob.glob(os.path.join(map_dir if field in rel_fields else ctx.root, p),
                                 recursive=True)
                if field not in rel_fields:
                    code += hits
                    continue
                for doc in hits:  # the feature's own recipe: editing it counts as editing the entry
                    if git_out(ctx.root, "status", "--porcelain", "--", doc):
                        edited = time.time()
                    last = (git_out(ctx.root, "log", "-1", "--format=%ct", "--", doc) or "").strip()
                    edited = max(edited, int(last) if last.isdigit() else 0)
        newer = commits_after(ctx.root, code, edited) if code else []
        if newer:
            stale.append((len(newer), f["fields"].get("id") or f["title"], edited, newer[0]))
    for count, fid, edited, (ts, rev, subject) in sorted(stale, key=lambda s: (-s[0], s[1])):
        log("%s: %d commit(s) to its code since the entry was edited (%s); latest %s %s \"%s\""
            % (fid, count, dt.date.fromtimestamp(edited).isoformat(), rev,
               dt.date.fromtimestamp(ts).isoformat(), subject))
    log("stale-map: %d of %d feature(s) to re-read%s" % (
        len(stale), len(features),
        ". Check each entry still describes the behaviour; correct it, or update its "
        "`reviewed:` date if it does" if stale else ""))
    return 1 if (stale and args.strict) else 0


# =============================================================== main

def main(argv=None):
    p = argparse.ArgumentParser(description="Build, run and check the app; collect evidence.")
    p.add_argument("--config", default=DEFAULT_CONFIG)
    p.add_argument("--map", default=None, help="feature map path (default: feature-map.md)")
    sub = p.add_subparsers(dest="cmd")
    sub.add_parser("doctor")
    sub.add_parser("list")
    sub.add_parser("build")
    r = sub.add_parser("run")
    r.add_argument("scenarios", nargs="*")
    r.add_argument("--all", action="store_true")
    r.add_argument("--build", action="store_true", help="run the build first")
    r.add_argument("--update-golden", action="store_true", help="rewrite golden files")
    u = sub.add_parser("up")
    u.add_argument("services", nargs="*")
    sub.add_parser("down")
    la = sub.add_parser("last")
    la.add_argument("scenario", nargs="?")
    c = sub.add_parser("compare")
    c.add_argument("scenario")
    sub.add_parser("check-map")
    am = sub.add_parser("audit-map", help="list map/recipe UI strings missing from the source")
    am.add_argument("--strict", action="store_true", help="exit 1 if anything is listed")
    sm = sub.add_parser("stale-map", help="list features whose code changed after their map entry")
    sm.add_argument("--strict", action="store_true", help="exit 1 if anything is listed")
    args = p.parse_args(argv)
    if not args.cmd:
        p.print_help()
        return 2
    if not os.path.exists(args.config):
        log("No config at %s. Create verify.config.json (see SKILL.md)." % args.config)
        return 2
    with open(args.config, "r", encoding="utf-8") as fh:
        cfg = json.load(fh)
    ctx = Ctx(cfg, args.config, update_golden=getattr(args, "update_golden", False))
    handlers = {"doctor": cmd_doctor, "list": cmd_list, "build": cmd_build, "run": cmd_run,
                "up": cmd_up, "down": cmd_down, "last": cmd_last, "compare": cmd_compare,
                "check-map": cmd_check_map, "audit-map": cmd_audit_map,
                "stale-map": cmd_stale_map}
    try:
        return handlers[args.cmd](ctx, args)
    except KeyboardInterrupt:
        stop_services(ctx)
        stop_xvfb(ctx)
        return 130


if __name__ == "__main__":
    sys.exit(main())
