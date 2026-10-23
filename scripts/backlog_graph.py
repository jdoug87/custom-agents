#!/usr/bin/env python3
"""Build the backlog dependency graph from GitHub issues.

Parses "Blocked By: #12, #13" lines in issue bodies, detects cycles and
dangling references, assigns execution tiers (1 = no open blockers), and
lists stories that are safe for an agent to claim.

Usage:
  backlog_graph.py                 JSON report: issues, tiers, cycles, ready queue
  backlog_graph.py --ready         ready issue numbers, highest priority first
  backlog_graph.py --apply-tiers   set tier:N labels and pull status:ready-for-agent
                                   off anything with open blockers (Roadmap agent only)

Env: APP_REPO (auto-detected from the installed copy at <app>/.claude/scripts). Python 3.9+, standard library only.
"""
import argparse
import json
import os
import re
import subprocess
import sys

SCRIPTS = os.path.dirname(os.path.realpath(__file__))


def default_app_repo(scripts_dir):
    """Mirror lib/common.sh: an installed copy lives at <app>/.claude/scripts."""
    parent = os.path.dirname(scripts_dir)
    if os.path.basename(parent) == ".claude":
        common = subprocess.run(["git", "-C", scripts_dir, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                check=True, capture_output=True, text=True).stdout.strip()
        return os.path.dirname(common)
    sys.exit("run the installed copy in your target repo (.claude/scripts), or set APP_REPO")


APP_REPO = os.environ.get("APP_REPO") or default_app_repo(SCRIPTS)

BLOCKED_BY_LINE = re.compile(r"^\s*[-*]?\s*\**blocked by:?\**(.*)$", re.IGNORECASE | re.MULTILINE)
ISSUE_REF = re.compile(r"#(\d+)")
PRIORITY_RANK = {"priority:high": 0, "priority:medium": 1, "priority:low": 2}
BUSY_LABELS = {"in-progress", "status:blocked", "status:pr-review"}


def gh_json(*args):
    out = subprocess.run(["gh", *args], cwd=APP_REPO, check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def parse_blockers(body):
    refs = []
    for match in BLOCKED_BY_LINE.finditer(body or ""):
        refs.extend(int(n) for n in ISSUE_REF.findall(match.group(1)))
    return refs


def load_issues():
    issues = gh_json("issue", "list", "--state", "all", "--limit", "1000",
                     "--json", "number,title,state,labels,body,assignees")
    return {i["number"]: i for i in issues}


def build_graph(all_issues):
    open_issues = {n: i for n, i in all_issues.items() if i["state"] == "OPEN"}
    graph = {}
    for n, issue in open_issues.items():
        refs = parse_blockers(issue["body"])
        graph[n] = {
            "number": n,
            "title": issue["title"],
            "labels": sorted(l["name"] for l in issue["labels"]),
            "assignees": [a["login"] for a in issue["assignees"]],
            "blocked_by": refs,
            "open_blockers": [r for r in refs if r in open_issues],
            "missing_refs": [r for r in refs if r not in all_issues],
        }
    return graph


def find_cycles(graph):
    cycles, state, stack = [], {}, []

    def visit(n):
        state[n] = "visiting"
        stack.append(n)
        for b in graph[n]["open_blockers"]:
            if state.get(b) == "visiting":
                cycles.append(stack[stack.index(b):] + [b])
            elif b not in state:
                visit(b)
        stack.pop()
        state[n] = "done"

    for n in sorted(graph):
        if n not in state:
            visit(n)
    return cycles


def assign_tiers(graph, cycles):
    in_cycle = {n for c in cycles for n in c}
    memo = {}

    def tier(n):
        if n in in_cycle:
            return None
        if n not in memo:
            blockers = [tier(b) for b in graph[n]["open_blockers"]]
            memo[n] = None if None in blockers else 1 + max(blockers, default=0)
        return memo[n]

    for n in graph:
        graph[n]["tier"] = tier(n)


def priority_rank(node):
    return min((PRIORITY_RANK[l] for l in node["labels"] if l in PRIORITY_RANK), default=3)


def ready_queue(graph):
    ready = [g for g in graph.values()
             if "status:ready-for-agent" in g["labels"]
             and g["tier"] == 1
             and not g["assignees"]
             and not BUSY_LABELS.intersection(g["labels"])]
    return sorted(ready, key=lambda g: (priority_rank(g), g["number"]))


def report():
    graph = build_graph(load_issues())
    cycles = find_cycles(graph)
    assign_tiers(graph, cycles)
    return graph, cycles


def apply_tiers(graph):
    for n, g in sorted(graph.items()):
        if g["tier"] is None:
            continue
        want = f"tier:{min(g['tier'], 3)}"
        args = ["issue", "edit", str(n)]
        if want not in g["labels"]:
            args += ["--add-label", want]
        args += [x for l in g["labels"] if l.startswith("tier:") and l != want for x in ("--remove-label", l)]
        if g["open_blockers"] and "status:ready-for-agent" in g["labels"]:
            args += ["--remove-label", "status:ready-for-agent", "--add-label", "status:backlog"]
        if len(args) > 3:
            subprocess.run(["gh", *args], cwd=APP_REPO, check=True, capture_output=True)
            print(f"#{n}: {' '.join(args[3:])}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ready", action="store_true")
    parser.add_argument("--apply-tiers", action="store_true")
    args = parser.parse_args()

    graph, cycles = report()
    if args.apply_tiers:
        apply_tiers(graph)
    if args.ready:
        for g in ready_queue(graph):
            print(g["number"])
        return
    if not args.apply_tiers:
        json.dump({
            "issues": [graph[n] for n in sorted(graph)],
            "cycles": cycles,
            "dangling": {n: g["missing_refs"] for n, g in graph.items() if g["missing_refs"]},
            "ready": [g["number"] for g in ready_queue(graph)],
        }, sys.stdout, indent=2)
        print()


if __name__ == "__main__":
    main()
