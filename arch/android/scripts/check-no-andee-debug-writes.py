#!/usr/bin/env python3

import pathlib
import sys


SCRIPT = pathlib.Path(__file__).resolve()
ROOTS = (SCRIPT.parent, SCRIPT.parents[3] / "scripts")
FORBIDDEN = {
    "run-as": "private app access",
    "adb push": "ADB file injection",
    '"$ADB" push': "ADB file injection",
    "/data/user/0/org.permaweb.andee": "direct app-private path access",
    "no_backup/": "direct app-private path access",
}


def main():
    failures = []
    for root in ROOTS:
        for path in sorted(root.iterdir()):
            if path.resolve() == SCRIPT or path.suffix not in {".py", ".sh"}:
                continue
            text = path.read_text(errors="replace")
            for needle, description in FORBIDDEN.items():
                if needle in text:
                    failures.append(f"{path}: {description} ({needle!r})")
    if failures:
        raise SystemExit(
            "AndEE debug-write backdoors are forbidden:\n  " + "\n  ".join(failures)
        )


if __name__ == "__main__":
    main()
