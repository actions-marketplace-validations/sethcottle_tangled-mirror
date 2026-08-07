#!/usr/bin/env python3
"""Pull the composite action's bash body out of action.yml so it can be linted
and exercised on its own. Avoids a PyYAML dependency: the block is the single
`run: |` literal in the file."""

import sys
from pathlib import Path

action = Path(__file__).resolve().parent.parent / "action.yml"
src = action.read_text()

marker = "      run: |\n"
if marker not in src:
    sys.exit(f"no '{marker.strip()}' block found in {action}")

body = src[src.index(marker) + len(marker):]
lines = []
for line in body.split("\n"):
    if line.strip() and not line.startswith("        "):
        break
    lines.append(line[8:] if line.startswith("        ") else line)

sys.stdout.write("\n".join(lines).rstrip() + "\n")
