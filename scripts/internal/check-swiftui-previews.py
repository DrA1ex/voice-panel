#!/usr/bin/env python3
"""Require Xcode previews for every production SwiftUI/AppKit representable view."""

from __future__ import annotations

import re
import sys
from pathlib import Path


VIEW_DECLARATION = re.compile(
    r"^\s*(?:private\s+|fileprivate\s+|internal\s+|public\s+)?struct\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)"
    r"(?:<[^>{}]+>)?\s*:\s*"
    r"(?:[^\n{]*\bView\b|NSViewRepresentable|NSViewControllerRepresentable)\s*\{",
    re.MULTILINE,
)


def production_source(source: str) -> str:
    lines: list[str] = []
    debug_depth = 0
    for line in source.splitlines(keepends=True):
        stripped = line.strip()
        if stripped.startswith("#if") and "DEBUG" in stripped:
            debug_depth += 1
            continue
        if stripped.startswith("#if") and debug_depth:
            debug_depth += 1
            continue
        if stripped.startswith("#endif") and debug_depth:
            debug_depth -= 1
            continue
        if debug_depth == 0:
            lines.append(line)
    return "".join(lines)


def preview_source(source: str) -> str:
    first_preview = source.find("#Preview")
    if first_preview < 0:
        return ""
    debug_start = source.rfind("#if DEBUG", 0, first_preview)
    return source[debug_start if debug_start >= 0 else first_preview :]


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: check-swiftui-previews.py SOURCES_DIR")

    source_root = Path(sys.argv[1])
    missing: list[str] = []
    discovered = 0

    for path in sorted(source_root.rglob("*.swift")):
        source = path.read_text()
        production = production_source(source)
        names = VIEW_DECLARATION.findall(production)
        if not names:
            continue

        previews = preview_source(source)
        for name in names:
            discovered += 1
            if not previews or re.search(rf"\b{re.escape(name)}\b", previews) is None:
                missing.append(f"{path.relative_to(source_root)}: {name}")

    if discovered == 0:
        raise SystemExit("No production SwiftUI views were discovered.")
    if missing:
        details = "\n".join(f"  - {item}" for item in missing)
        raise SystemExit(f"Missing #Preview coverage:\n{details}")

    print(f"SwiftUI preview coverage passed for {discovered} views.", file=sys.stderr)


if __name__ == "__main__":
    main()
