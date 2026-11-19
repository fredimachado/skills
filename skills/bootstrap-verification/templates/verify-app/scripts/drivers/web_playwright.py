#!/usr/bin/env python3
"""
web_playwright.py: drive a web UI (or an Electron/Chromium app via CDP) with Playwright
and collect evidence: screenshots, console errors, performance metrics, traces, heap
snapshots.

Usage:
  web_playwright.py --url http://localhost:3000 --steps steps.json [options]
  web_playwright.py --cdp http://localhost:9222 --steps steps.json   # attach to Electron/Chrome

Options:
  --out DIR                 evidence dir (default: $VERIFY_RUN_DIR or .)
  --browser chromium|firefox|webkit   (default chromium; perf/heap need chromium)
  --headed                  show the browser
  --viewport 1280x800
  --fail-on-console-error   fail if the page logs console errors or throws
  --trace                   save a Playwright trace (open with `playwright show-trace`)
  --perf-trace              save a Chromium performance trace (open in DevTools > Performance)
  --metrics NAME            write page metrics to OUT/metrics/NAME.json (picked up by verify.py)
  --heap-snapshot           save a JS heap snapshot at the end (Chromium only)

Steps (JSON list, run in order). Selectors are Playwright selectors, e.g. "#id",
"text=Save", "role=button[name='Save']", "[data-testid=cart]":
  {"goto": "http://..."}             {"click": "selector"}
  {"fill": ["selector", "text"]}     {"press": "Control+K"}  or  {"press": ["selector", "Enter"]}
  {"wait_for": "selector", "timeout": 10000}
  {"expect_text": "Saved"}           {"expect_no_text": "Error"}
  {"expect_visible": "selector"}     {"expect_count": ["selector", 3]}
  {"expect_url": "regex"}
  {"screenshot": "name"}             {"screenshot": "name", "selector": "#panel"}
  {"eval": "js expression", "save_as": "metric_name"}   numeric results become metrics
  {"mark": "label"}                  record elapsed ms since start as metric mark.label
  {"sleep": 200}                     last resort; prefer wait_for

Requires: pip install playwright && python -m playwright install chromium
"""
import argparse
import json
import os
import re
import sys
import time


def main():
    p = argparse.ArgumentParser(description="Drive a web UI and collect evidence.")
    p.add_argument("--url")
    p.add_argument("--cdp", help="attach to a running Chromium/Electron (remote debugging URL)")
    p.add_argument("--steps")
    p.add_argument("--step", action="append", help="one JSON step (repeatable)")
    p.add_argument("--out")
    p.add_argument("--browser", default="chromium")
    p.add_argument("--headed", action="store_true")
    p.add_argument("--viewport", default="1280x800")
    p.add_argument("--fail-on-console-error", action="store_true")
    p.add_argument("--trace", action="store_true")
    p.add_argument("--perf-trace", action="store_true")
    p.add_argument("--metrics")
    p.add_argument("--heap-snapshot", action="store_true")
    args = p.parse_args()

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("web_playwright: Playwright is not installed. Run:\n"
              "  pip install playwright && python -m playwright install chromium", file=sys.stderr)
        return 2

    steps = []
    if args.steps:
        with open(args.steps, "r", encoding="utf-8") as fh:
            steps = json.load(fh)
    steps += [json.loads(s) for s in args.step or []]
    if args.url:
        steps.insert(0, {"goto": args.url})
    out = args.out or os.environ.get("VERIFY_RUN_DIR") or "."
    os.makedirs(out, exist_ok=True)
    w, h = (int(x) for x in args.viewport.lower().split("x"))

    console_errors, metrics = [], {}
    failed = None
    t_start = time.time()
    with sync_playwright() as pw:
        if args.cdp:
            browser = pw.chromium.connect_over_cdp(args.cdp)
            context = browser.contexts[0] if browser.contexts else browser.new_context()
            page = context.pages[0] if context.pages else context.new_page()
        else:
            browser = getattr(pw, args.browser).launch(headless=not args.headed)
            context = browser.new_context(viewport={"width": w, "height": h})
            page = context.new_page()

        page.on("console", lambda m: console_errors.append("console.%s: %s" % (m.type, m.text))
                if m.type == "error" else None)
        page.on("pageerror", lambda e: console_errors.append("pageerror: %s" % e))
        if args.trace:
            context.tracing.start(screenshots=True, snapshots=True, sources=False)
        if args.perf_trace and args.browser == "chromium":
            browser.start_tracing(page=page, path=os.path.join(out, "perf-trace.json"),
                                  screenshots=True)

        for i, step in enumerate(steps, 1):
            try:
                do_step(page, step, out, metrics, t_start)
                print("  step %d ok   %s" % (i, json.dumps(step)))
            except Exception as exc:  # Playwright raises many error types
                failed = "step %d %s: %s" % (i, json.dumps(step), str(exc).splitlines()[0])
                print("  step %d FAIL %s" % (i, failed))
                try:
                    page.screenshot(path=os.path.join(out, "failure.png"), full_page=True)
                except Exception:
                    pass
                break

        if args.metrics or args.perf_trace:
            metrics.update(page_metrics(page, context, args.browser))
        if args.perf_trace and args.browser == "chromium":
            browser.stop_tracing()
        if args.heap_snapshot and args.browser == "chromium":
            heap_snapshot(page, context, os.path.join(out, "heap.heapsnapshot"))
        if args.trace:
            context.tracing.stop(path=os.path.join(out, "playwright-trace.zip"))
        if not args.cdp:
            browser.close()

    with open(os.path.join(out, "console-errors.txt"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(console_errors))
    metrics["console_errors"] = len(console_errors)
    if args.metrics:
        mdir = os.path.join(out, "metrics")
        os.makedirs(mdir, exist_ok=True)
        with open(os.path.join(mdir, args.metrics + ".json"), "w", encoding="utf-8") as fh:
            json.dump({"%s.%s" % (args.metrics, k): v for k, v in metrics.items()}, fh, indent=2)
    if not failed and args.fail_on_console_error and console_errors:
        failed = "%d console error(s): %s" % (len(console_errors), console_errors[0])
    if failed:
        print("web_playwright: FAILED: " + failed)
        return 1
    print("web_playwright: OK (%d steps, %d console errors)" % (len(steps), len(console_errors)))
    return 0


def do_step(page, step, out, metrics, t_start):
    timeout = step.get("timeout", 10000)
    if "goto" in step:
        page.goto(step["goto"], wait_until=step.get("wait_until", "load"), timeout=timeout * 3)
    elif "click" in step:
        page.locator(step["click"]).first.click(timeout=timeout)
    elif "fill" in step:
        sel, text = step["fill"]
        page.locator(sel).first.fill(text, timeout=timeout)
    elif "press" in step:
        if isinstance(step["press"], list):
            page.locator(step["press"][0]).first.press(step["press"][1], timeout=timeout)
        else:
            page.keyboard.press(step["press"])
    elif "wait_for" in step:
        page.locator(step["wait_for"]).first.wait_for(timeout=timeout)
    elif "expect_text" in step:
        page.get_by_text(step["expect_text"]).first.wait_for(timeout=timeout)
    elif "expect_no_text" in step:
        if page.get_by_text(step["expect_no_text"]).count() > 0:
            raise AssertionError("text %r is present" % step["expect_no_text"])
    elif "expect_visible" in step:
        page.locator(step["expect_visible"]).first.wait_for(state="visible", timeout=timeout)
    elif "expect_count" in step:
        sel, n = step["expect_count"]
        got = page.locator(sel).count()
        if got != n:
            raise AssertionError("%s count is %d, expected %d" % (sel, got, n))
    elif "expect_url" in step:
        if not re.search(step["expect_url"], page.url):
            raise AssertionError("url %s does not match /%s/" % (page.url, step["expect_url"]))
    elif "screenshot" in step:
        path = os.path.join(out, step["screenshot"] + ".png")
        if step.get("selector"):
            page.locator(step["selector"]).first.screenshot(path=path)
        else:
            page.screenshot(path=path, full_page=step.get("full_page", True))
    elif "eval" in step:
        val = page.evaluate(step["eval"])
        if step.get("save_as") and isinstance(val, (int, float)):
            metrics[step["save_as"]] = val
    elif "mark" in step:
        metrics["mark.%s" % step["mark"]] = int((time.time() - t_start) * 1000)
    elif "sleep" in step:
        page.wait_for_timeout(step["sleep"])
    else:
        raise ValueError("unknown step")


def page_metrics(page, context, browser_name):
    m = {}
    try:
        nav = page.evaluate("""() => {
            const n = performance.getEntriesByType('navigation')[0];
            const p = Object.fromEntries(performance.getEntriesByType('paint').map(e => [e.name, e.startTime]));
            return n ? {dom_content_loaded_ms: n.domContentLoadedEventEnd, load_ms: n.loadEventEnd,
                        ttfb_ms: n.responseStart, fcp_ms: p['first-contentful-paint'] || null} : {};
        }""")
        m.update({k: round(v, 1) for k, v in nav.items() if isinstance(v, (int, float))})
    except Exception:
        pass
    if browser_name == "chromium":
        try:
            cdp = context.new_cdp_session(page)
            cdp.send("Performance.enable")
            for item in cdp.send("Performance.getMetrics")["metrics"]:
                if item["name"] in ("JSHeapUsedSize", "JSHeapTotalSize", "Nodes",
                                    "JSEventListeners", "LayoutCount", "RecalcStyleCount",
                                    "TaskDuration", "ScriptDuration", "LayoutDuration"):
                    m[item["name"]] = round(item["value"], 3)
        except Exception:
            pass
    return m


def heap_snapshot(page, context, path):
    cdp = context.new_cdp_session(page)
    chunks = []
    cdp.on("HeapProfiler.addHeapSnapshotChunk", lambda p: chunks.append(p["chunk"]))
    cdp.send("HeapProfiler.enable")
    cdp.send("HeapProfiler.collectGarbage")
    cdp.send("HeapProfiler.takeHeapSnapshot", {"reportProgress": False})
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("".join(chunks))


if __name__ == "__main__":
    sys.exit(main())
