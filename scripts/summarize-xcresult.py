#!/usr/bin/env python3
"""Print a compact pass/fail summary of an .xcresult bundle.

Usage: summarize-xcresult.py <path-to-xcresult>
Relies on `xcrun xcresulttool` (DEVELOPER_DIR should point at Xcode).
"""
import json
import os
import subprocess
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: summarize-xcresult.py <path-to-xcresult>", file=sys.stderr)
        return 2
    bundle = sys.argv[1]
    try:
        out = subprocess.check_output(
            ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle],
            stderr=subprocess.DEVNULL,
        )
        d = json.loads(out)
    except Exception as exc:  # noqa: BLE001 - best-effort summary
        print("  (could not read result bundle: {})".format(exc))
        return 0

    print("  result : {}".format(d.get("result")))
    print("  passed : {}".format(d.get("passedTests")))
    print("  failed : {}".format(d.get("failedTests")))
    print("  skipped: {}".format(d.get("skippedTests")))
    for f in d.get("testFailures", []):
        print("  ✗ {}: {}".format(f.get("testName"), f.get("failureText")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
