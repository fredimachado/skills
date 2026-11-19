#!/usr/bin/env python3
"""
guard.py: a zero-dependency, language-agnostic pattern guard.

Encodes "never do X here" rules as regexes over files, with baselines so you can
freeze existing violations ("stop the bleeding") and fail only on new ones.

Rules:     .agent/guards.json            (committed)
Baseline:  .agent/guards-baseline.json   (committed)

Usage (run from the repo root, or pass --root):
  guard.py check [--rule ID] [--json] [--no-baseline]
  guard.py baseline [--rule ID]
  guard.py list
  guard.py test-rule ID FILE

Exit codes: 0 = clean, 1 = new violations, 2 = configuration/usage error.

There is deliberately no inline "ignore" comment. Exceptions belong in the rule's
`exclude` list, where they're visible in review, rather than scattered through the code
where agents will copy them.

Requires Python 3.8+. No third-party packages.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict

CONFIG_DEFAULT = os.path.join(".agent", "guards.json")
BASELINE_DEFAULT = os.path.join(".agent", "guards-baseline.json")
SKIP_DIRS = {
    ".git", "node_modules", ".venv", "venv", "__pycache__", "dist", "build", "out",
    "target", "bin", "obj", ".next", ".nuxt", ".gradle", ".idea", ".vs", "vendor",
    ".verify", ".agent",
}
MAX_FILE_BYTES = 2 * 1024 * 1024


# ---------------------------------------------------------------- globbing

_glob_cache = {}


def glob_to_regex(pattern):
    """Translate a glob with ** support into a compiled regex over '/'-separated paths.

    A pattern without '/' matches the file's basename anywhere (like .gitignore),
    so "*.test.ts" works without writing "**/*.test.ts".
    """
    if pattern in _glob_cache:
        return _glob_cache[pattern]
    pat = pattern.replace("\\", "/")
    basename_only = "/" not in pat
    i, out = 0, []
    while i < len(pat):
        c = pat[i]
        if c == "*":
            if pat[i:i + 3] == "**/":
                out.append("(?:.*/)?")
                i += 3
                continue
            if pat[i:i + 2] == "**":
                out.append(".*")
                i += 2
                continue
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        elif c == "[":
            j = pat.find("]", i + 1)
            if j == -1:
                out.append(re.escape(c))
            else:
                cls = pat[i + 1:j]
                if cls.startswith("!"):
                    cls = "^" + cls[1:]
                out.append("[" + cls + "]")
                i = j
        else:
            out.append(re.escape(c))
        i += 1
    body = "".join(out)
    rx = re.compile(("(?:.*/)?" if basename_only else "") + body + r"\Z")
    _glob_cache[pattern] = rx
    return rx


def path_matches(path, patterns):
    return any(glob_to_regex(p).match(path) for p in patterns)


# ---------------------------------------------------------------- files

def list_files(root):
    """Prefer git (respects .gitignore, includes untracked-but-not-ignored files)."""
    try:
        res = subprocess.run(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            cwd=root, capture_output=True, check=True,
        )
        files = [f for f in res.stdout.decode("utf-8", "replace").split("\0") if f]
        return sorted({f for f in files if os.path.isfile(os.path.join(root, f))})
    except (OSError, subprocess.CalledProcessError):
        pass
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            rel = os.path.relpath(os.path.join(dirpath, name), root).replace(os.sep, "/")
            found.append(rel)
    return sorted(found)


def read_text(path):
    try:
        if os.path.getsize(path) > MAX_FILE_BYTES:
            return None
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return None
    if b"\0" in data[:8192]:
        return None  # binary
    return data.decode("utf-8", "replace")


# ---------------------------------------------------------------- config

def load_json(path, default=None):
    if not os.path.exists(path):
        return default
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def load_rules(config_path):
    cfg = load_json(config_path)
    if cfg is None:
        die("No rules file at %s. Create it with a {\"rules\": [...]} object." % config_path)
    rules, ids = [], set()
    for idx, r in enumerate(cfg.get("rules", [])):
        rid = r.get("id")
        if not rid or "pattern" not in r:
            die("Rule #%d needs at least 'id' and 'pattern'." % idx)
        if rid in ids:
            die("Duplicate rule id: %s" % rid)
        ids.add(rid)
        flags = 0
        if r.get("multiline"):
            flags |= re.MULTILINE | re.DOTALL
        if r.get("ignore_case"):
            flags |= re.IGNORECASE
        try:
            rx = re.compile(r["pattern"], flags)
        except re.error as exc:
            die("Rule %s has an invalid regex: %s" % (rid, exc))
        severity = r.get("severity", "error")
        if severity not in ("error", "warn"):
            die("Rule %s: severity must be 'error' or 'warn'." % rid)
        rules.append({
            "id": rid,
            "rx": rx,
            "include": r.get("include") or ["**"],
            "exclude": r.get("exclude") or [],
            "message": r.get("message", "Forbidden pattern (rule %s)." % rid),
            "reason": r.get("reason", ""),
            "severity": severity,
        })
    return rules


def die(msg):
    print("guard: " + msg, file=sys.stderr)
    sys.exit(2)


# ---------------------------------------------------------------- scanning

def match_key(text, m):
    """Baseline key: the full source line(s) of the match, whitespace-collapsed.

    Using the whole line (not just the matched text) means "fetch(" in two different
    places counts separately, while the key still survives line-number shifts.
    """
    start = text.rfind("\n", 0, m.start()) + 1
    end = text.find("\n", m.end())
    end = len(text) if end == -1 else end
    return " ".join(text[start:end].split())


def scan(root, rules, files):
    """Return {rule_id: {path: [ {line, col, key, text} ]}}."""
    results = {r["id"]: defaultdict(list) for r in rules}
    for rel in files:
        applicable = [r for r in rules
                      if path_matches(rel, r["include"]) and not path_matches(rel, r["exclude"])]
        if not applicable:
            continue
        text = read_text(os.path.join(root, rel))
        if text is None:
            continue
        for r in applicable:
            for m in r["rx"].finditer(text):
                line = text.count("\n", 0, m.start()) + 1
                col = m.start() - (text.rfind("\n", 0, m.start()) + 1) + 1
                results[r["id"]][rel].append({
                    "line": line, "col": col, "key": match_key(text, m),
                    "text": m.group(0)[:200],
                })
    return results


def new_violations(rule_hits, baseline_for_rule):
    """Hits beyond the baselined count for each (file, key)."""
    out = []
    for path, hits in rule_hits.items():
        allowed = dict((baseline_for_rule or {}).get(path, {}))
        for h in hits:
            if allowed.get(h["key"], 0) > 0:
                allowed[h["key"]] -= 1
            else:
                out.append(dict(h, path=path))
    return out


# ---------------------------------------------------------------- commands

def cmd_check(args, rules, root):
    if args.rule:
        rules = [r for r in rules if r["id"] == args.rule]
        if not rules:
            die("Unknown rule: %s" % args.rule)
    baseline = {} if args.no_baseline else load_json(args.baseline, {})
    results = scan(root, rules, list_files(root))
    report, errors, warnings = [], 0, 0
    for r in rules:
        for v in new_violations(results[r["id"]], baseline.get(r["id"])):
            report.append({"rule": r["id"], "severity": r["severity"], "path": v["path"],
                           "line": v["line"], "col": v["col"], "match": v["text"],
                           "message": r["message"], "reason": r["reason"]})
            if r["severity"] == "error":
                errors += 1
            else:
                warnings += 1
    if args.json:
        print(json.dumps({"errors": errors, "warnings": warnings, "violations": report}, indent=2))
    else:
        for v in report:
            print("%s:%d:%d: %s [%s] %s" % (v["path"], v["line"], v["col"], v["severity"],
                                            v["rule"], v["message"]))
        status = "FAILED" if errors else "OK"
        print("guard: %s (%d error(s), %d warning(s), %d rule(s) checked)"
              % (status, errors, warnings, len(rules)))
    return 1 if errors else 0


def cmd_baseline(args, rules, root):
    baseline = load_json(args.baseline, {}) or {}
    target = [r for r in rules if not args.rule or r["id"] == args.rule]
    if args.rule and not target:
        die("Unknown rule: %s" % args.rule)
    results = scan(root, target, list_files(root))
    total = 0
    for r in target:
        per_file = {}
        for path, hits in sorted(results[r["id"]].items()):
            counts = defaultdict(int)
            for h in hits:
                counts[h["key"]] += 1
                total += 1
            per_file[path] = dict(sorted(counts.items()))
        if per_file:
            baseline[r["id"]] = per_file
        else:
            baseline.pop(r["id"], None)
    # drop baselines for rules that no longer exist
    known = {r["id"] for r in rules}
    baseline = {k: v for k, v in baseline.items() if k in known}
    os.makedirs(os.path.dirname(args.baseline) or ".", exist_ok=True)
    with open(args.baseline, "w", encoding="utf-8") as fh:
        json.dump(baseline, fh, indent=2, sort_keys=True)
        fh.write("\n")
    print("guard: baselined %d existing violation(s) across %d rule(s) -> %s"
          % (total, len(target), args.baseline))
    return 0


def cmd_list(args, rules, root):
    baseline = load_json(args.baseline, {}) or {}
    results = scan(root, rules, list_files(root))
    print("%-32s %-6s %8s %10s %6s" % ("RULE", "SEV", "CURRENT", "BASELINED", "NEW"))
    for r in rules:
        current = sum(len(h) for h in results[r["id"]].values())
        based = sum(sum(c.values()) for c in baseline.get(r["id"], {}).values())
        new = len(new_violations(results[r["id"]], baseline.get(r["id"])))
        print("%-32s %-6s %8d %10d %6d" % (r["id"], r["severity"], current, based, new))
    return 0


def cmd_test_rule(args, rules, root):
    rule = next((r for r in rules if r["id"] == args.rule_id), None)
    if not rule:
        die("Unknown rule: %s" % args.rule_id)
    rel = os.path.relpath(os.path.abspath(args.file), root).replace(os.sep, "/")
    applies = path_matches(rel, rule["include"]) and not path_matches(rel, rule["exclude"])
    print("file %s is %s by include/exclude" % (rel, "SELECTED" if applies else "NOT selected"))
    text = read_text(args.file)
    if text is None:
        die("Cannot read %s as text." % args.file)
    n = 0
    for m in rule["rx"].finditer(text):
        n += 1
        line = text.count("\n", 0, m.start()) + 1
        print("  line %d: %s" % (line, match_key(text, m)))
    print("%d match(es)" % n)
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description="Language-agnostic pattern guard with baselines.")
    p.add_argument("--root", default=".", help="repository root (default: cwd)")
    p.add_argument("--config", default=None, help="rules file (default: .agent/guards.json)")
    p.add_argument("--baseline", default=None,
                   help="baseline file (default: .agent/guards-baseline.json)")
    sub = p.add_subparsers(dest="cmd")
    c = sub.add_parser("check", help="fail on violations not in the baseline")
    c.add_argument("--rule")
    c.add_argument("--json", action="store_true")
    c.add_argument("--no-baseline", action="store_true", help="report every violation")
    b = sub.add_parser("baseline", help="freeze current violations")
    b.add_argument("--rule")
    sub.add_parser("list", help="rules with current/baselined/new counts")
    t = sub.add_parser("test-rule", help="show what a rule matches in one file")
    t.add_argument("rule_id")
    t.add_argument("file")
    args = p.parse_args(argv)
    if not args.cmd:
        args.cmd = "check"
        args.rule, args.json, args.no_baseline = None, False, False

    root = os.path.abspath(args.root)
    args.config = args.config or os.path.join(root, CONFIG_DEFAULT)
    args.baseline = args.baseline or os.path.join(root, BASELINE_DEFAULT)
    rules = load_rules(args.config)
    handler = {"check": cmd_check, "baseline": cmd_baseline, "list": cmd_list,
               "test-rule": cmd_test_rule}[args.cmd]
    return handler(args, rules, root)


if __name__ == "__main__":
    sys.exit(main())
