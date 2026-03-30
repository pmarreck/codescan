#!/usr/bin/env python3
"""Analyze Claude Code transcript files to compare token usage with/without codescan tools.

Parses JSONL transcript files from ~/.claude/projects/*/sessions/ and reports:
- Per-tool token usage (input + output)
- Codescan MCP tools vs built-in tools (Read/Grep/Glob/Edit)
- Session-level summaries

Usage:
    python3 scripts/token-usage-analyzer.py [--sessions-dir DIR] [--last N]
"""

import json
import os
import sys
import argparse
from pathlib import Path
from collections import defaultdict
from datetime import datetime


def find_session_dirs(base_dir=None):
    """Find all Claude Code session directories."""
    if base_dir:
        return [Path(base_dir)]

    claude_dir = Path.home() / ".claude" / "projects"
    if not claude_dir.exists():
        print(f"No Claude projects found at {claude_dir}", file=sys.stderr)
        return []

    sessions = []
    for project_dir in claude_dir.iterdir():
        if not project_dir.is_dir():
            continue
        # Session files are directly in the project dir
        for f in project_dir.glob("*.jsonl"):
            sessions.append(f)

    return sorted(sessions, key=lambda p: p.stat().st_mtime, reverse=True)


def parse_transcript(path):
    """Parse a JSONL transcript file and extract tool usage with token counts."""
    tool_stats = defaultdict(lambda: {"calls": 0, "input_tokens": 0, "output_tokens": 0})
    session_totals = {"input_tokens": 0, "output_tokens": 0, "turns": 0}
    session_date = None

    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue

                if not session_date and entry.get("timestamp"):
                    session_date = entry["timestamp"][:10]

                msg = entry.get("message", {})
                if entry.get("type") != "assistant":
                    continue

                usage = msg.get("usage", {})
                input_tokens = usage.get("input_tokens", 0) + usage.get("cache_read_input_tokens", 0) + usage.get("cache_creation_input_tokens", 0)
                output_tokens = usage.get("output_tokens", 0)

                session_totals["input_tokens"] += input_tokens
                session_totals["output_tokens"] += output_tokens
                session_totals["turns"] += 1

                # Extract tool calls from content
                content = msg.get("content", [])
                for block in content:
                    if block.get("type") == "tool_use":
                        tool_name = block.get("name", "unknown")
                        tool_stats[tool_name]["calls"] += 1
                        # Attribute this turn's tokens to the tool
                        # (rough — a turn may have multiple tool calls)
                        tool_stats[tool_name]["input_tokens"] += input_tokens
                        tool_stats[tool_name]["output_tokens"] += output_tokens
    except Exception as e:
        print(f"Error parsing {path}: {e}", file=sys.stderr)

    return {
        "path": str(path),
        "date": session_date,
        "tools": dict(tool_stats),
        "totals": session_totals,
    }


BUILTIN_TOOLS = {"Read", "Grep", "Glob", "Edit", "Write", "Agent"}
CODESCAN_TOOLS = {
    "mcp__codescan__search", "mcp__codescan__symbols", "mcp__codescan__read_file",
    "mcp__codescan__replace_content", "mcp__codescan__replace_symbol",
    "mcp__codescan__replace_lines", "mcp__codescan__insert_at",
    "mcp__codescan__insert_after", "mcp__codescan__insert_before",
    "mcp__codescan__create_file", "mcp__codescan__destroy_file",
    "mcp__codescan__diff", "mcp__codescan__references", "mcp__codescan__rename",
    "mcp__codescan__config", "mcp__codescan__status", "mcp__codescan__index",
    "mcp__codescan__query",
}


def categorize_tool(name):
    """Categorize a tool as builtin, codescan, or other."""
    if name in BUILTIN_TOOLS:
        return "builtin"
    if name in CODESCAN_TOOLS or name.startswith("mcp__codescan__"):
        return "codescan"
    return "other"


def print_report(sessions, last_n=None):
    """Print a summary report of token usage."""
    if last_n:
        sessions = sessions[:last_n]

    print(f"\n{'='*70}")
    print(f"Claude Code Token Usage Report — {len(sessions)} session(s)")
    print(f"{'='*70}\n")

    # Aggregate across sessions
    agg_builtin = {"calls": 0, "input_tokens": 0, "output_tokens": 0}
    agg_codescan = {"calls": 0, "input_tokens": 0, "output_tokens": 0}
    agg_other = {"calls": 0, "input_tokens": 0, "output_tokens": 0}
    total_tokens = 0

    tool_details = defaultdict(lambda: {"calls": 0, "input_tokens": 0, "output_tokens": 0})

    for session in sessions:
        for tool_name, stats in session["tools"].items():
            cat = categorize_tool(tool_name)
            target = {"builtin": agg_builtin, "codescan": agg_codescan, "other": agg_other}[cat]
            target["calls"] += stats["calls"]
            target["input_tokens"] += stats["input_tokens"]
            target["output_tokens"] += stats["output_tokens"]

            tool_details[tool_name]["calls"] += stats["calls"]
            tool_details[tool_name]["input_tokens"] += stats["input_tokens"]
            tool_details[tool_name]["output_tokens"] += stats["output_tokens"]

        total_tokens += session["totals"]["input_tokens"] + session["totals"]["output_tokens"]

    # Category summary
    print("Category Summary (tokens = input + output attributed to tool-call turns):\n")
    print(f"  {'Category':<20} {'Calls':>8} {'Input Tokens':>14} {'Output Tokens':>14} {'Total':>14}")
    print(f"  {'-'*20} {'-'*8} {'-'*14} {'-'*14} {'-'*14}")
    for label, agg in [("Built-in tools", agg_builtin), ("Codescan MCP", agg_codescan), ("Other", agg_other)]:
        total = agg["input_tokens"] + agg["output_tokens"]
        print(f"  {label:<20} {agg['calls']:>8} {agg['input_tokens']:>14,} {agg['output_tokens']:>14,} {total:>14,}")

    print(f"\n  Total session tokens: {total_tokens:,}\n")

    # Top tools by call count
    print("Top tools by call count:\n")
    sorted_tools = sorted(tool_details.items(), key=lambda x: x[1]["calls"], reverse=True)
    print(f"  {'Tool':<40} {'Cat':<10} {'Calls':>8} {'Tokens':>14}")
    print(f"  {'-'*40} {'-'*10} {'-'*8} {'-'*14}")
    for tool_name, stats in sorted_tools[:20]:
        cat = categorize_tool(tool_name)
        total = stats["input_tokens"] + stats["output_tokens"]
        print(f"  {tool_name:<40} {cat:<10} {stats['calls']:>8} {total:>14,}")

    # Codescan adoption ratio
    builtin_nav = sum(
        tool_details[t]["calls"]
        for t in ["Read", "Grep", "Glob"]
        if t in tool_details
    )
    codescan_nav = sum(
        stats["calls"]
        for t, stats in tool_details.items()
        if t.startswith("mcp__codescan__") and t in {
            "mcp__codescan__search", "mcp__codescan__symbols",
            "mcp__codescan__read_file", "mcp__codescan__query",
        }
    )

    if builtin_nav + codescan_nav > 0:
        ratio = codescan_nav / (builtin_nav + codescan_nav) * 100
        print(f"\n  Codescan adoption (navigation): {codescan_nav}/{builtin_nav + codescan_nav} calls ({ratio:.1f}%)")

    builtin_edit = sum(
        tool_details[t]["calls"]
        for t in ["Edit", "Write"]
        if t in tool_details
    )
    codescan_edit = sum(
        stats["calls"]
        for t, stats in tool_details.items()
        if t.startswith("mcp__codescan__") and t in {
            "mcp__codescan__replace_content", "mcp__codescan__replace_symbol",
            "mcp__codescan__replace_lines", "mcp__codescan__insert_at",
            "mcp__codescan__insert_after", "mcp__codescan__insert_before",
            "mcp__codescan__create_file", "mcp__codescan__destroy_file",
        }
    )

    if builtin_edit + codescan_edit > 0:
        ratio = codescan_edit / (builtin_edit + codescan_edit) * 100
        print(f"  Codescan adoption (editing):    {codescan_edit}/{builtin_edit + codescan_edit} calls ({ratio:.1f}%)")

    print()


def main():
    parser = argparse.ArgumentParser(description="Analyze Claude Code token usage")
    parser.add_argument("--sessions-dir", help="Directory containing JSONL transcript files")
    parser.add_argument("--last", type=int, default=10, help="Analyze last N sessions (default: 10)")
    parser.add_argument("--all", action="store_true", help="Analyze all sessions")
    args = parser.parse_args()

    session_files = find_session_dirs(args.sessions_dir)
    if not session_files:
        print("No session files found.", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(session_files)} session file(s)", file=sys.stderr)

    sessions = []
    for path in session_files:
        if path.is_file() and path.suffix == ".jsonl":
            sessions.append(parse_transcript(path))
        elif path.is_dir():
            for f in sorted(path.glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True):
                sessions.append(parse_transcript(f))

    # Filter to sessions that have tool usage
    sessions = [s for s in sessions if s["tools"]]

    last_n = None if args.all else args.last
    print_report(sessions, last_n)


if __name__ == "__main__":
    main()
