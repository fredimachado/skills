#!/usr/bin/env python3
"""
scan.py: find code patterns that tend to spread when agents copy them, and show
whether they're growing.

Counts generic "weed" signals (workaround markers, lint/type suppressions, swallowed
errors, sleep-based waits, disabled tests, debug leftovers, loose types, tests that can't
fail, rules that live only in comments, oversized files) plus project-specific signals and
competing-implementation "families" from .agent/garden.json. Optionally compares against
an earlier git revision or the last saved snapshot so you can see what's spreading.

Usage (from the repo root):
  scan.py                       # report for the working tree
  scan.py --since-days 30       # also compare with the repo as it was 30 days ago
  scan.py --compare-rev v1.2.0  # compare with any git revision
  scan.py --save                # save a snapshot to .agent/garden/snapshots/
  scan.py --compare-last        # compare with the most recent saved snapshot
  scan.py --json                # machine-readable output

Requires Python 3.8+ and (for --since-days/--compare-rev) git. No third-party packages.
"""
import argparse
import datetime as dt
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
from collections import defaultdict

SKIP_DIRS = {
    ".git", "node_modules", ".venv", "venv", "__pycache__", "dist", "build", "out",
    "target", "bin", "obj", ".next", ".nuxt", ".gradle", ".idea", ".vs", "vendor",
    ".verify", ".agent", "coverage", "third_party", "external",
}
SKIP_EXT = {
    ".png", ".jpg", ".jpeg", ".gif", ".ico", ".svg", ".pdf", ".zip", ".gz", ".lock",
    ".woff", ".woff2", ".ttf", ".mp4", ".mp3", ".min.js", ".map", ".snap",
}
DOC_EXT = {".md", ".rst", ".txt", ".adoc"}
MAX_FILE_BYTES = 1024 * 1024
LARGE_FILE_LINES = 800
# Files that hold tests, by the common naming conventions across ecosystems.
TEST_PATH_RX = (r"(?i)(?:^|/)(?:tests?|specs?|__tests__|e2e)/"
                r"|[._-](?:test|spec)s?\.[a-z]+$"
                r"|(?:^|/)test_[^/]*$"
                r"|(?-i:[a-z0-9]Tests?\.[a-z]+$)")

# Built-in signals. Each is a hint for a human/agent to look at, not a verdict.
SIGNALS = {
    "workaround-marker": {
        "why": "Markers of known shortcuts. Agents read them as permission to add more.",
        "patterns": [
            r"\b(?:TODO|FIXME|HACK|XXX|KLUDGE)\b",
            r"(?i)\b(?:workaround|work-around|band-?aid|quick fix|temp(?:orary)? fix|for now|until we)\b",
        ],
        "code_only": True,
    },
    "suppression": {
        "why": "Silenced compiler/linter/type checks. Each one is a hole in the guard rails.",
        "patterns": [
            r"eslint-disable", r"@ts-(?:ignore|nocheck|expect-error)", r"#\s*type:\s*ignore",
            r"#\s*noqa", r"pylint:\s*disable", r"#pragma\s+warning\s+disable",
            r"\[SuppressMessage\(", r"@SuppressWarnings\(", r"//\s*nolint", r"#\[allow\(",
            r"NOLINT", r"NOSONAR", r"qmllint\s+disable", r"shellcheck\s+disable",
            r"rubocop:disable", r"biome-ignore", r"@phpstan-ignore", r"swiftlint:disable",
        ],
        "code_only": True,
    },
    "swallowed-error": {
        "why": "Errors caught and dropped. Hides bugs, and gets copied as 'how errors are handled here'.",
        "patterns": [
            r"catch\s*(?:\([^)]*\))?\s*\{\s*\}",
            r"except(?:\s+[\w.]+(?:\s+as\s+\w+)?)?\s*:\s*\n\s*pass\b",
            r"catch\s*\(\s*\.\.\.\s*\)\s*\{\s*\}",
            r"\.catch\(\s*\(\s*\w*\s*\)\s*=>\s*\{\s*\}\s*\)",
            r"\.catch\(\s*\(\)\s*=>\s*(?:null|undefined|void 0)\s*\)",
        ],
        "code_only": True,
    },
    "sleep-sync": {
        "why": "Sleeps used to wait for something. Flaky, slow, and very easy to copy.",
        "patterns": [
            r"\b(?:time\.sleep|Thread\.Sleep|Task\.Delay|usleep|msleep|QThread::(?:m|u)?sleep|QTest::qWait)\s*\(",
            r"std::this_thread::sleep_for", r"\bwaitForTimeout\s*\(",
            r"setTimeout\([^\n]*?,\s*0\s*\)",
            r"\bcy\.wait\(\s*\d+", r"\bsleep\s+\d",
        ],
        "code_only": True,
    },
    "disabled-test": {
        "why": "Tests switched off. Coverage that silently disappeared.",
        "patterns": [
            r"\b(?:it|test|describe)\.skip\(", r"\bx(?:it|describe|test)\(",
            r"@pytest\.mark\.skip\b", r"@unittest\.skip", r"\[Ignore\b", r"Skip\s*=\s*\"",
            r"@Disabled\b", r"@Ignore\b", r"\bt\.Skip\(", r"#\[ignore\]", r"\bQSKIP\(",
            r"GTEST_SKIP\(", r"DISABLED_\w+",
        ],
        "code_only": True,
    },
    "debug-leftover": {
        "why": "Debug output left in code. Noisy, and agents treat it as the logging convention.",
        "patterns": [
            r"\bconsole\.(?:log|debug)\(", r"^\s*debugger;", r"\bdbg!\(",
            r"\bSystem\.out\.println\(", r"\bConsole\.WriteLine\(\s*\"DEBUG", r"\bbreakpoint\(\)",
        ],
        "code_only": True,
    },
    "loose-type": {
        "why": "Escapes from the type system. Each one makes the next one look acceptable.",
        "patterns": [
            r"\bas\s+any\b", r":\s*any\b(?!\w)", r"\bas\s+unknown\s+as\b", r"<any>",
            r"\bdynamic\s+\w+\s*=", r"\breinterpret_cast<", r"\bunsafe\s*\{",
        ],
        "code_only": True,
    },
    "vacuous-test": {
        "why": "Assertions that pass whatever the code returns (exists, truthy, was called, "
               "didn't throw). Tests that can't fail get copied as the testing style.",
        "patterns": [
            r"\.toBe(?:Defined|Truthy)\(\)", r"\.not\.toBe(?:Null|Undefined)\(\)",
            r"\.not\.toThrow\(\)", r"\.toHaveBeenCalled\(\)",
            r"\bassert\s+True\b", r"^\s*assert\s+[\w.]+\s+is\s+not\s+None\s*$",
            r"\bassert(?:True|IsTrue)\(\s*[Tt]rue\s*\)", r"\bassert!\(\s*true\s*\)",
            r"\bassert(?:Is)?NotNone\(", r"\.assert_called(?:_once)?\(\)",
            r"\bAssert\.(?:NotNull|IsNotNull|Pass)\(", r"\bAssert\.(?:True|IsTrue)\(\s*true\s*\)",
            r"\bassertNotNull\(", r"\bassertDoesNotThrow\(",
            r"\b(?:assert|require)\.NotNil\(",
            r"\bassert!\([^;\n]*\.is_(?:ok|some)\(\)\s*\)",
            r"\bEXPECT_NO_THROW\(", r"\bEXPECT_TRUE\(\s*true\s*\)", r"\bQVERIFY\(\s*true\s*\)",
        ],
        "code_only": True,
        "path_regex": TEST_PATH_RX,
    },
    "constraint-comment": {
        "why": "Rules that live only in a comment ('do not remove', 'keep in sync'). Nothing "
               "enforces them; each is a candidate for a type, a test or a guard.",
        "patterns": [
            r"(?i)\b(?:do not|don'?t|never)\s+(?:remove|delete|change|touch|reorder|rename|move)\b",
            r"(?i)\b(?:keep|kept|stay|stays|must be|needs? to be)\b[^\n]{0,40}\bin sync\b",
            r"(?i)\bmust\s+(?:match|mirror|stay the same as|be the same as)\b",
            r"(?i)\bif you (?:change|update|edit|modify|rename) this\b",
        ],
        "code_only": True,
    },
}


# ---------------------------------------------------------------- files

def list_files(root, use_git=True):
    if use_git:
        try:
            res = subprocess.run(
                ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                cwd=root, capture_output=True, check=True,
            )
            files = [f for f in res.stdout.decode("utf-8", "replace").split("\0") if f]
            return sorted(f for f in set(files)
                          if os.path.isfile(os.path.join(root, f)) and not skipped(f))
        except (OSError, subprocess.CalledProcessError):
            pass
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            rel = os.path.relpath(os.path.join(dirpath, name), root).replace(os.sep, "/")
            if not skipped(rel):
                found.append(rel)
    return sorted(found)


def skipped(rel):
    parts = rel.split("/")
    if any(p in SKIP_DIRS for p in parts[:-1]):
        return True
    low = rel.lower()
    return any(low.endswith(ext) for ext in SKIP_EXT)


def read_text(path):
    try:
        if os.path.getsize(path) > MAX_FILE_BYTES:
            return None
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return None
    if b"\0" in data[:8192]:
        return None
    return data.decode("utf-8", "replace")


# ---------------------------------------------------------------- config

def load_config(root):
    path = os.path.join(root, ".agent", "garden.json")
    if not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def compile_signals(cfg):
    signals = {}
    disabled = set(cfg.get("disable", []))
    for name, s in SIGNALS.items():
        if name in disabled:
            continue
        signals[name] = dict(s, rx=[re.compile(p, re.MULTILINE) for p in s["patterns"]])
    for name, s in (cfg.get("signals") or {}).items():
        signals[name] = {
            "why": s.get("why", "Project-specific signal."),
            "patterns": s["patterns"],
            "code_only": s.get("code_only", True),
            "path_regex": s.get("path_regex"),
            "rx": [re.compile(p, re.MULTILINE) for p in s["patterns"]],
        }
    for s in signals.values():
        s["path_rx"] = re.compile(s["path_regex"]) if s.get("path_regex") else None
    return signals


def compile_families(cfg):
    fams = {}
    for name, alts in (cfg.get("families") or {}).items():
        fams[name] = {alt: re.compile(rx, re.MULTILINE) for alt, rx in alts.items()}
    return fams


# ---------------------------------------------------------------- scanning

def scan_tree(root, cfg, use_git=True):
    signals = compile_signals(cfg)
    families = compile_families(cfg)
    exclude = [re.compile(p) for p in cfg.get("exclude_regex", [])]
    large_limit = int(cfg.get("large_file_lines", LARGE_FILE_LINES))

    by_signal = defaultdict(lambda: defaultdict(int))      # signal -> file -> count
    family_use = defaultdict(lambda: defaultdict(lambda: defaultdict(int)))  # fam -> alt -> file -> n
    large = {}
    files = list_files(root, use_git)
    for rel in files:
        if any(rx.search(rel) for rx in exclude):
            continue
        text = read_text(os.path.join(root, rel))
        if text is None:
            continue
        is_doc = os.path.splitext(rel)[1].lower() in DOC_EXT
        for name, s in signals.items():
            if is_doc and s["code_only"]:
                continue
            if s["path_rx"] and not s["path_rx"].search(rel):
                continue
            n = sum(len(rx.findall(text)) for rx in s["rx"])
            if n:
                by_signal[name][rel] += n
        if not is_doc:
            for fam, alts in families.items():
                for alt, rx in alts.items():
                    n = len(rx.findall(text))
                    if n:
                        family_use[fam][alt][rel] += n
            lines = text.count("\n") + 1
            if lines >= large_limit:
                large[rel] = lines

    return {
        "scanned_files": len(files),
        "signals": {k: dict(v) for k, v in by_signal.items()},
        "families": {f: {a: dict(fl) for a, fl in alts.items()} for f, alts in family_use.items()},
        "large_files": large,
        "signal_info": {k: v["why"] for k, v in signals.items()},
    }


def totals(snapshot):
    sig = {k: sum(v.values()) for k, v in snapshot["signals"].items()}
    fams = {f: {a: sum(fl.values()) for a, fl in alts.items()}
            for f, alts in snapshot["families"].items()}
    return sig, fams


# ---------------------------------------------------------------- comparison sources

def resolve_rev_days_ago(root, days):
    res = subprocess.run(
        ["git", "rev-list", "-1", "--before=%d days ago" % days, "HEAD"],
        cwd=root, capture_output=True, text=True,
    )
    rev = res.stdout.strip()
    return rev or None


def scan_rev(root, rev, cfg):
    """Export the tree at `rev` with git archive and scan it."""
    res = subprocess.run(["git", "archive", "--format=tar", rev], cwd=root, capture_output=True)
    if res.returncode != 0:
        raise RuntimeError(res.stderr.decode("utf-8", "replace").strip())
    with tempfile.TemporaryDirectory(prefix="garden-") as tmp:
        with tarfile.open(fileobj=io.BytesIO(res.stdout)) as tar:
            members = [m for m in tar.getmembers()
                       if not (m.name.startswith("/") or ".." in m.name.split("/"))]
            if hasattr(tarfile, "data_filter"):
                tar.extractall(tmp, members=members, filter="data")
            else:
                tar.extractall(tmp, members=members)
        return scan_tree(tmp, cfg, use_git=False)


def snapshot_dir(root):
    return os.path.join(root, ".agent", "garden", "snapshots")


def last_snapshot(root):
    d = snapshot_dir(root)
    if not os.path.isdir(d):
        return None, None
    names = sorted(n for n in os.listdir(d) if n.endswith(".json"))
    if not names:
        return None, None
    with open(os.path.join(d, names[-1]), "r", encoding="utf-8") as fh:
        return names[-1], json.load(fh)


# ---------------------------------------------------------------- reporting

def growth_files(now, before, signal, limit):
    cur = now["signals"].get(signal, {})
    old = (before or {}).get("signals", {}).get(signal, {})
    deltas = [(f, n - old.get(f, 0), n) for f, n in cur.items() if n - old.get(f, 0) > 0]
    deltas.sort(key=lambda x: (-x[1], x[0]))
    return deltas[:limit]


def render_markdown(now, before, label, top):
    sig_now, fam_now = totals(now)
    sig_old, fam_old = totals(before) if before else ({}, {})
    out = ["# Garden scan", ""]
    out.append("Scanned %d files." % now["scanned_files"]
               + (" Compared with: %s." % label if before else ""))
    out += ["", "## Signals", ""]
    out.append("| Signal | Count | Change | Files | Why it matters |")
    out.append("|---|---:|---:|---:|---|")
    names = sorted(set(sig_now) | set(sig_old), key=lambda s: -sig_now.get(s, 0))
    for s in names:
        n, o = sig_now.get(s, 0), sig_old.get(s, 0)
        change = ("%+d" % (n - o)) if before else "–"
        out.append("| %s | %d | %s | %d | %s |" % (
            s, n, change, len(now["signals"].get(s, {})), now["signal_info"].get(s, "")))

    out += ["", "## Hotspots by signal", ""]
    for s in names:
        files = now["signals"].get(s, {})
        if not files:
            continue
        ranked = sorted(files.items(), key=lambda x: (-x[1], x[0]))[:top]
        out.append("**%s**: " % s + ", ".join("`%s` (%d)" % (f, c) for f, c in ranked))
        if before:
            grew = growth_files(now, before, s, top)
            if grew:
                out.append("  - grew in: " + ", ".join("`%s` (+%d)" % (f, d) for f, d, _ in grew))
        out.append("")

    out += ["## Competing implementations", ""]
    if not fam_now and not fam_old:
        out.append("No families configured. Add them to `.agent/garden.json` (see the garden skill).")
    else:
        for fam in sorted(set(fam_now) | set(fam_old)):
            alts = fam_now.get(fam, {})
            in_use = [a for a, c in alts.items() if c]
            flag = "  ⚠ %d ways in use" % len(in_use) if len(in_use) > 1 else ""
            out.append("**%s**%s" % (fam, flag))
            for a in sorted(set(alts) | set(fam_old.get(fam, {}))):
                c, o = alts.get(a, 0), fam_old.get(fam, {}).get(a, 0)
                files = len(now["families"].get(fam, {}).get(a, {}))
                change = (" (%+d)" % (c - o)) if before else ""
                out.append("- %s: %d use(s) in %d file(s)%s" % (a, c, files, change))
            out.append("")

    out += ["## Large files", ""]
    if now["large_files"]:
        for f, n in sorted(now["large_files"].items(), key=lambda x: -x[1])[:top]:
            out.append("- `%s`: %d lines" % (f, n))
    else:
        out.append("None over the threshold.")
    out.append("")
    return "\n".join(out)


def main(argv=None):
    p = argparse.ArgumentParser(description="Find spreading anti-patterns.")
    p.add_argument("--root", default=".")
    p.add_argument("--since-days", type=int, help="compare with the repo N days ago (git)")
    p.add_argument("--compare-rev", help="compare with a git revision")
    p.add_argument("--compare-last", action="store_true", help="compare with last saved snapshot")
    p.add_argument("--save", action="store_true", help="save snapshot to .agent/garden/snapshots/")
    p.add_argument("--top", type=int, default=8, help="files listed per signal")
    p.add_argument("--json", action="store_true")
    args = p.parse_args(argv)

    root = os.path.abspath(args.root)
    cfg = load_config(root)
    now = scan_tree(root, cfg)

    before, label = None, None
    try:
        if args.compare_rev:
            before, label = scan_rev(root, args.compare_rev, cfg), "git revision %s" % args.compare_rev
        elif args.since_days:
            rev = resolve_rev_days_ago(root, args.since_days)
            if rev:
                before = scan_rev(root, rev, cfg)
                label = "repo %d days ago (%s)" % (args.since_days, rev[:10])
            else:
                print("scan: no commit older than %d days; skipping comparison" % args.since_days,
                      file=sys.stderr)
        elif args.compare_last:
            name, before = last_snapshot(root)
            label = "snapshot %s" % name if before else None
            if not before:
                print("scan: no saved snapshot yet; skipping comparison", file=sys.stderr)
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        print("scan: comparison failed: %s" % exc, file=sys.stderr)
        before = None

    if args.save:
        d = snapshot_dir(root)
        os.makedirs(d, exist_ok=True)
        name = dt.datetime.now().strftime("%Y-%m-%dT%H%M%S") + ".json"
        with open(os.path.join(d, name), "w", encoding="utf-8") as fh:
            json.dump(now, fh, indent=1, sort_keys=True)
        print("scan: saved snapshot %s" % os.path.join(d, name), file=sys.stderr)

    if args.json:
        sig_now, fam_now = totals(now)
        payload = {"now": now, "totals": {"signals": sig_now, "families": fam_now}}
        if before:
            sig_old, fam_old = totals(before)
            payload["compared_with"] = label
            payload["before_totals"] = {"signals": sig_old, "families": fam_old}
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(render_markdown(now, before, label, args.top))
    return 0


if __name__ == "__main__":
    sys.exit(main())
