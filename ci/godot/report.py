#!/usr/bin/env python3
"""Test result helpers for the Godot pipelines (standard library only).

  report.py summary RESULTS_DIR --runner NAME [--exit-code N]
      Reads every JUnit (*.junit.xml) and TRX (*.trx) file under RESULTS_DIR, prints totals,
      and on GitHub Actions appends a job summary and emits ::error annotations for failures.

  report.py godottest-junit LOG OUT
      Converts a Chickensoft GoDotTest console log into JUnit XML.
"""
import argparse
import os
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

MAX_ANNOTATIONS = 20
LOCATION = re.compile(r"(?:in |at )?((?:/|[A-Za-z]:\\|res://)[^\s:]+\.(?:cs|gd))(?::line |:)(\d+)")


@dataclass
class Failure:
    name: str
    message: str
    details: str = ""


@dataclass
class Totals:
    total: int = 0
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    failures: list = field(default_factory=list)


def strip_ns(root):
    for el in root.iter():
        if "}" in el.tag:
            el.tag = el.tag.split("}", 1)[1]
    return root


def read_junit(path, totals):
    root = strip_ns(ET.parse(path).getroot())
    for case in root.iter("testcase"):
        totals.total += 1
        problem = case.find("failure")
        if problem is None:
            problem = case.find("error")
        if problem is not None:
            totals.failed += 1
            name = f"{case.get('classname', '')}.{case.get('name', '')}".strip(".")
            totals.failures.append(Failure(name, problem.get("message") or "", problem.text or ""))
        elif case.find("skipped") is not None or case.get("status") in ("pending", "skipped"):
            totals.skipped += 1
        else:
            totals.passed += 1


def read_trx(path, totals):
    root = strip_ns(ET.parse(path).getroot())
    for result in root.iter("UnitTestResult"):
        outcome = result.get("outcome", "")
        totals.total += 1
        if outcome == "Passed":
            totals.passed += 1
        elif outcome in ("Failed", "Error", "Timeout", "Aborted"):
            totals.failed += 1
            message = result.findtext("Output/ErrorInfo/Message") or outcome
            stack = result.findtext("Output/ErrorInfo/StackTrace") or ""
            totals.failures.append(Failure(result.get("testName", "?"), message, stack))
        else:
            totals.skipped += 1


def annotation(runner, failure):
    def esc(text, prop=False):
        text = text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        return text.replace(":", "%3A").replace(",", "%2C") if prop else text

    props = [f"title={esc(f'{runner}: {failure.name}', True)}"]
    match = LOCATION.search(failure.details) or LOCATION.search(failure.message)
    if match:
        path = match.group(1)
        workspace = os.environ.get("GITHUB_WORKSPACE", "")
        if workspace and path.startswith(workspace):
            path = os.path.relpath(path, workspace)
        if not path.startswith("res://"):
            props += [f"file={esc(path, True)}", f"line={match.group(2)}"]
    print(f"::error {','.join(props)}::{esc(failure.message.strip() or 'failed')}")


def summary(args):
    results = Path(args.results)
    totals = Totals()
    for path in sorted(results.rglob("*")):
        if "coverage" in path.parts or not path.is_file():
            continue
        try:
            if path.name.endswith(".junit.xml"):
                read_junit(path, totals)
            elif path.suffix == ".trx":
                read_trx(path, totals)
        except ET.ParseError as error:
            print(f"[godot-ci] Could not parse {path}: {error}", file=sys.stderr)

    ok = args.exit_code == 0 and totals.failed == 0
    icon = "✅" if ok else "❌"
    line = f"{args.runner}: {totals.passed} passed, {totals.failed} failed, {totals.skipped} skipped"
    print(f"[godot-ci] {line}")
    if totals.total == 0:
        print(f"[godot-ci] {args.runner} reported no test results (exit code {args.exit_code})", file=sys.stderr)
        ok, icon = False, "❌"

    if os.environ.get("GITHUB_ACTIONS"):
        for failure in totals.failures[:MAX_ANNOTATIONS]:
            annotation(args.runner, failure)

    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        write_summary(summary_file, args, totals, results, icon)
    return 0 if totals.total > 0 else 1


def write_summary(summary_file, args, totals, results, icon):
    out = [f"### {icon} Godot tests: `{args.runner}`", "",
           "| Total | Passed | Failed | Skipped |", "|---:|---:|---:|---:|",
           f"| {totals.total} | {totals.passed} | {totals.failed} | {totals.skipped} |", ""]
    if totals.total == 0:
        out += [f"No test results were reported (exit code {args.exit_code}); see the job log.", ""]
    for failure in totals.failures[:50]:
        detail = failure.details if failure.message.strip() in failure.details else f"{failure.message}\n{failure.details}"
        out += [f"<details><summary><code>{escape(failure.name)}</code></summary>", "",
                "```", detail.strip()[:3000], "```", "</details>", ""]
    coverage = results / "coverage" / "report" / "SummaryGithub.md"
    if coverage.exists():
        out += ["<details><summary>Coverage</summary>", "", coverage.read_text(), "</details>", ""]
    with open(summary_file, "a", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")


GOTEST_RESULT = re.compile(r">\s*(OK|!!)\s*>>\s*([\w.`+]+)::(\w+) \[Test\] > Test (passed|failed)")
GOTEST_ERROR = re.compile(r">\s*!!\s*>>\s*([\w.`+]+)::(\w+) \[Test\] > Error occurred: (.*)")


def godottest_junit(args):
    lines = Path(args.log).read_text(errors="replace").splitlines()
    cases, errors = {}, {}
    for i, line in enumerate(lines):
        if m := GOTEST_RESULT.search(line):
            cases[(m.group(2), m.group(3))] = m.group(4)
        elif m := GOTEST_ERROR.search(line):
            detail = [m.group(3)]
            for follow in lines[i + 1:]:
                if follow.startswith("Info (GoTest)") or re.match(r"^\s*(Error: \d+ :|$)", follow):
                    break
                detail.append(follow)
            # The exception dump that follows carries the stack trace with file and line.
            for follow in lines[i + len(detail):i + len(detail) + 40]:
                if follow.startswith("Info (GoTest)"):
                    break
                detail.append(follow)
            errors[(m.group(1), m.group(2))] = "\n".join(detail)

    suites = {}
    for (suite, test), outcome in cases.items():
        suites.setdefault(suite, []).append((test, outcome, errors.get((suite, test), "")))
    xml = ['<?xml version="1.0" encoding="UTF-8"?>', "<testsuites>"]
    for suite, tests in suites.items():
        failed = sum(1 for _, o, _ in tests if o == "failed")
        xml.append(f'  <testsuite name={quoteattr(suite)} tests="{len(tests)}" failures="{failed}">')
        for test, outcome, detail in tests:
            xml.append(f"    <testcase classname={quoteattr(suite)} name={quoteattr(test)}>")
            if outcome == "failed":
                first = detail.splitlines()[0] if detail else "Test failed"
                xml.append(f"      <failure message={quoteattr(first)}>{escape(detail)}</failure>")
            xml.append("    </testcase>")
        xml.append("  </testsuite>")
    xml.append("</testsuites>")
    Path(args.out).write_text("\n".join(xml) + "\n")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("summary")
    s.add_argument("results")
    s.add_argument("--runner", required=True)
    s.add_argument("--exit-code", type=int, default=0)
    g = sub.add_parser("godottest-junit")
    g.add_argument("log")
    g.add_argument("out")
    args = parser.parse_args()
    sys.exit({"summary": summary, "godottest-junit": godottest_junit}[args.command](args) or 0)


if __name__ == "__main__":
    main()
