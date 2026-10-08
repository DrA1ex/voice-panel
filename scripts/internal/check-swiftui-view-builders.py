#!/usr/bin/env python3
"""Catch result-builder omissions that syntax-only Swift checks cannot see.

The Linux Swift toolchain can parse macOS/SwiftUI files but cannot type-check
against AppKit and SwiftUI without the macOS SDK. This checker targets a common
semantic regression: a declaration returning ``some View`` contains multiple
root expressions or result-builder control flow but is missing ``@ViewBuilder``.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


DECLARATION_RE = re.compile(
    r"(?m)^(?P<indent>[ \t]*)"
    r"(?:(?:private|fileprivate|internal|package|public|open|nonisolated|static|class|final)\s+)*"
    r"(?:"
    r"var\s+(?P<property>[A-Za-z_][A-Za-z0-9_]*)\s*:\s*some\s+View\s*"
    r"|"
    r"func\s+(?P<function>[A-Za-z_][A-Za-z0-9_]*)\b[^\n{]*->\s*some\s+View\s*"
    r")\{"
)


@dataclass
class Diagnostic:
    path: Path
    line: int
    name: str
    reason: str


def mask_non_code(text: str) -> str:
    """Replace comments and string contents while preserving layout."""
    out = list(text)
    i = 0
    block_depth = 0
    string_mode: str | None = None
    escaped = False

    while i < len(text):
        if block_depth:
            if text.startswith("/*", i):
                out[i : i + 2] = "  "
                block_depth += 1
                i += 2
            elif text.startswith("*/", i):
                out[i : i + 2] = "  "
                block_depth -= 1
                i += 2
            else:
                if text[i] != "\n":
                    out[i] = " "
                i += 1
            continue

        if string_mode:
            if string_mode == '"""' and text.startswith('"""', i):
                out[i : i + 3] = "   "
                string_mode = None
                i += 3
                continue
            if string_mode == '"' and text[i] == '"' and not escaped:
                out[i] = " "
                string_mode = None
                i += 1
                continue
            escaped = text[i] == "\\" and not escaped
            if text[i] != "\n":
                out[i] = " "
            if text[i] != "\\":
                escaped = False
            i += 1
            continue

        if text.startswith("//", i):
            end = text.find("\n", i)
            if end == -1:
                end = len(text)
            for j in range(i, end):
                out[j] = " "
            i = end
            continue
        if text.startswith("/*", i):
            out[i : i + 2] = "  "
            block_depth = 1
            i += 2
            continue
        if text.startswith('"""', i):
            out[i : i + 3] = "   "
            string_mode = '"""'
            i += 3
            continue
        if text[i] == '"':
            out[i] = " "
            string_mode = '"'
            escaped = False
            i += 1
            continue
        i += 1

    return "".join(out)


def find_matching_brace(masked: str, opening: int) -> int | None:
    depth = 0
    for index in range(opening, len(masked)):
        char = masked[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index
    return None


def has_view_builder(source: str, declaration_start: int) -> bool:
    line_start = source.rfind("\n", 0, declaration_start) + 1
    cursor = line_start
    while cursor > 0:
        previous_end = cursor - 1
        previous_start = source.rfind("\n", 0, previous_end) + 1
        line = source[previous_start:previous_end].strip()
        if not line:
            cursor = previous_start
            continue
        return line.startswith("@ViewBuilder")
    return False


def top_level_starts(body: str) -> tuple[list[tuple[int, str]], bool]:
    """Return root statement starts and whether builder-only control flow exists."""
    starts: list[tuple[int, str]] = []
    brace = paren = bracket = 0
    control_flow = False

    for line_number, raw_line in enumerate(body.splitlines(), start=1):
        stripped = raw_line.strip()
        at_root = brace == 0 and paren == 0 and bracket == 0

        if at_root and stripped:
            normalized = stripped.lstrip(";")
            ignored_prefixes = (
                ".",
                ")",
                "]",
                "}",
                "else",
                "catch",
                "while ",
                "#else",
                "#endif",
            )
            declaration_prefixes = (
                "let ",
                "var ",
                "typealias ",
                "defer ",
            )
            if normalized.startswith(("if ", "if let ", "if case ", "switch ", "for ")):
                control_flow = True
            if not normalized.startswith(ignored_prefixes + declaration_prefixes):
                starts.append((line_number, normalized))

        # Masked input makes braces inside strings/comments harmless.
        for char in raw_line:
            if char == "{":
                brace += 1
            elif char == "}":
                brace = max(0, brace - 1)
            elif char == "(":
                paren += 1
            elif char == ")":
                paren = max(0, paren - 1)
            elif char == "[":
                bracket += 1
            elif char == "]":
                bracket = max(0, bracket - 1)

    return starts, control_flow


def analyze(path: Path) -> list[Diagnostic]:
    source = path.read_text(encoding="utf-8")
    masked = mask_non_code(source)
    diagnostics: list[Diagnostic] = []

    for match in DECLARATION_RE.finditer(masked):
        if has_view_builder(source, match.start()):
            continue
        opening = masked.find("{", match.start(), match.end())
        closing = find_matching_brace(masked, opening)
        if closing is None:
            continue  # swiftc -parse reports this separately.
        body = masked[opening + 1 : closing]
        starts, control_flow = top_level_starts(body)
        name = match.group("property") or match.group("function") or "<unknown>"
        declaration_line = source.count("\n", 0, match.start()) + 1

        if control_flow:
            diagnostics.append(
                Diagnostic(path, declaration_line, name, "contains top-level control flow")
            )
        elif len(starts) > 1:
            diagnostics.append(
                Diagnostic(
                    path,
                    declaration_line,
                    name,
                    f"contains {len(starts)} top-level view expressions",
                )
            )

    return diagnostics


def swift_files(paths: list[str]) -> list[Path]:
    files: list[Path] = []
    for raw in paths:
        path = Path(raw)
        if path.is_dir():
            files.extend(sorted(path.rglob("*.swift")))
        elif path.suffix == ".swift":
            files.append(path)
    return files


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+", help="Swift files or directories")
    args = parser.parse_args()

    diagnostics = [diagnostic for path in swift_files(args.paths) for diagnostic in analyze(path)]
    for diagnostic in diagnostics:
        print(
            f"{diagnostic.path}:{diagnostic.line}: error: '{diagnostic.name}' returns some View, "
            f"{diagnostic.reason}, but is missing @ViewBuilder",
            file=sys.stderr,
        )
    return 1 if diagnostics else 0


if __name__ == "__main__":
    raise SystemExit(main())
