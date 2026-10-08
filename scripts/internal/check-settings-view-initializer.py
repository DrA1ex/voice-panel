#!/usr/bin/env python3
"""Verify that the SettingsView call follows its explicit initializer contract."""

from __future__ import annotations

import re
import sys
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(message)


def balanced_parenthesized_content(text: str, marker: str, start: int = 0) -> str:
    marker_index = text.find(marker, start)
    if marker_index < 0:
        fail(f"could not find {marker!r}")

    open_index = text.find("(", marker_index + len(marker) - 1)
    if open_index < 0:
        fail(f"could not find opening parenthesis for {marker!r}")

    depth = 0
    in_string = False
    escaped = False
    line_comment = False
    block_comment_depth = 0
    index = open_index

    while index < len(text):
        char = text[index]
        next_char = text[index + 1] if index + 1 < len(text) else ""

        if line_comment:
            if char == "\n":
                line_comment = False
            index += 1
            continue

        if block_comment_depth:
            if char == "/" and next_char == "*":
                block_comment_depth += 1
                index += 2
                continue
            if char == "*" and next_char == "/":
                block_comment_depth -= 1
                index += 2
                continue
            index += 1
            continue

        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue

        if char == "/" and next_char == "/":
            line_comment = True
            index += 2
            continue
        if char == "/" and next_char == "*":
            block_comment_depth = 1
            index += 2
            continue
        if char == '"':
            in_string = True
            index += 1
            continue

        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return text[open_index + 1 : index]

        index += 1

    fail(f"unterminated parenthesized expression for {marker!r}")
    return ""


def top_level_segments(content: str) -> list[str]:
    segments: list[str] = []
    start = 0
    depths = {"(": 0, "[": 0, "{": 0, "<": 0}
    matching_open = {")": "(",
        "]": "[",
        "}": "{",
        ">": "<",
    }
    in_string = False
    escaped = False

    for index, char in enumerate(content):
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue

        if char == '"':
            in_string = True
            continue

        if char in depths:
            depths[char] += 1
            continue
        if char in matching_open:
            opening = matching_open[char]
            depths[opening] = max(0, depths[opening] - 1)
            continue

        if char == "," and all(depth == 0 for depth in depths.values()):
            segment = content[start:index].strip()
            if segment:
                segments.append(segment)
            start = index + 1

    final = content[start:].strip()
    if final:
        segments.append(final)
    return segments


def labels(content: str) -> list[str]:
    result: list[str] = []
    for segment in top_level_segments(content):
        match = re.match(r"(?:_[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)\s*:", segment)
        if not match:
            fail(f"could not determine argument label from: {segment!r}")
        result.append(match.group(1))
    return result


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: check-settings-view-initializer.py SETTINGS_VIEW CONTROLLER")

    settings_text = Path(sys.argv[1]).read_text()
    controller_text = Path(sys.argv[2]).read_text()

    struct_start = settings_text.find("struct SettingsView")
    if struct_start < 0:
        fail("SettingsView declaration is missing")

    initializer_content = balanced_parenthesized_content(
        settings_text,
        "init(",
        start=struct_start,
    )
    call_content = balanced_parenthesized_content(controller_text, "SettingsView(")

    initializer_labels = labels(initializer_content)
    call_labels = labels(call_content)

    if call_labels != initializer_labels:
        fail(
            "SettingsView call labels do not match its explicit initializer order:\n"
            f"  initializer: {initializer_labels}\n"
            f"  call:        {call_labels}"
        )



if __name__ == "__main__":
    main()
