#!/usr/bin/env python3
"""
parse_test_summary.py -- read a Chromium --test-launcher-summary-output JSON
and print which tests failed.

WHY THIS IS NOT DONE IN POWERSHELL
----------------------------------
PowerShell 5.1's ConvertFrom-Json builds a case-INSENSITIVE dictionary, and
Chromium's parameterised test names legitimately differ only by case. On the
zen5 base_unittests summary it dies outright:

    Cannot convert the JSON string because a dictionary that was converted
    from the string contains the duplicated keys
    'FeatureListCountryRestrictionTests/FeatureListCountryRestrictionTest.Evaluation/DE'
    and '.../de'.

That is unfixable from the PowerShell side -- the keys really are distinct and
the parser really does fold them together -- so the parse happens here, where
dict keys are case-sensitive. It is also far faster on a 6 MB summary.

Output, one record per line, for easy consumption by the caller:

    RAN <n>
    FAILED <test name>
    ...

A test counts as failed only when NO attempt succeeded, so a flake that passed
on retry is not reported as a failure.
"""

import argparse
import json
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--summary", required=True, help="test-launcher-summary-output JSON")
    args = ap.parse_args()

    try:
        with open(args.summary, "r", encoding="utf-8", errors="replace") as f:
            data = json.load(f)
    except Exception as e:
        print(f"ERROR could not read {args.summary}: {type(e).__name__}: {e}", file=sys.stderr)
        return 2

    iterations = data.get("per_iteration_data") or []
    if not iterations:
        print(f"ERROR no per_iteration_data in {args.summary}", file=sys.stderr)
        return 2

    # Union across iterations: a name is failed only if it never succeeded in
    # any iteration/attempt. --gtest_repeat and launcher retries both land here.
    succeeded = set()
    seen = set()
    for it in iterations:
        if not isinstance(it, dict):
            continue
        for name, attempts in it.items():
            seen.add(name)
            for a in attempts or []:
                if isinstance(a, dict) and a.get("status") == "SUCCESS":
                    succeeded.add(name)

    failed = sorted(seen - succeeded)
    print(f"RAN {len(seen)}")
    for name in failed:
        print(f"FAILED {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
