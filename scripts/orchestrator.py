#!/usr/bin/env python3
"""Orchestrator / Dispatcher loop for the agent pipeline.

Each tick it reads GitHub and herdr state and moves work along the pipeline:

  RFC PR opened              -> trigger_rfc_swarm.sh (security/perf/dx reviewers)
  RFC PR merged              -> roadmap-prioritizer
  Story ready + unblocked    -> claim_issue.sh, worktree, feature-developer
  PR in status:pr-review     -> qa-tester, security-auditor (+ visual-regression,
                                design-systems when the PR touches UI files)
  PR with a failed check     -> feature-developer rework (max MAX_REWORK cycles, then escalate)
  PR qa:passed               -> the single merge-master
  Blocked, not yet notified  -> hitl-dispatcher
  Finished agents            -> close herdr workspace, remove worktree
  Stalled agents             -> notify the human

The orchestrator never writes code, merges, or prioritizes. Run exactly one.

Usage: orchestrator.py [--once] [--dry-run] [--interval SECONDS]
Env caps: MAX_DEV (6), MAX_QA (4), MAX_REVIEWERS (6), MAX_REWORK (2), STALL_MINUTES (45)
Python 3.9+, standard library only.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import backlog_graph  # noqa: E402

SCRIPTS = os.path.dirname(os.path.realpath(__file__))
APP_REPO = os.environ.get("APP_REPO") or backlog_graph.default_app_repo(SCRIPTS)
os.environ.setdefault("APP_REPO", APP_REPO)

MAX_DEV = int(os.environ.get("MAX_DEV", 6))
MAX_QA = int(os.environ.get("MAX_QA", 4))
MAX_REVIEWERS = int(os.environ.get("MAX_REVIEWERS", 6))
MAX_REWORK = int(os.environ.get("MAX_REWORK", 2))
STALL_MINUTES = int(os.environ.get("STALL_MINUTES", 45))
BLOCKED_DIALOG_MINUTES = 5

UI_PATHS = ("app/views/", "app/assets/", "app/helpers/", "app/javascript/")
FAILURE_LABELS = ("qa:failed", "security:failed", "visual:failed", "design:changes-requested", "integration-failed")
# Per-PR verification agents: (herdr name prefix, agent definition, label prefix, ui-only, prompt)
PR_CHECKS = [
    ("qa", "qa-tester", "qa:", False,
     "Run QA verification on PR #{pr}. Label the result with $AGENT_SCRIPTS/set_status.sh pr {pr} qa:passed|qa:failed."),
    ("sec", "security-auditor", "security:", False,
     "Run the Mode 1 pre-merge scan on PR #{pr} ($AGENT_SCRIPTS/security_scan.sh {pr}). Label security:passed|security:failed."),
    ("vis", "visual-regression", "visual:", True,
     "Run visual regression and record walkthroughs for PR #{pr}. Label visual:passed|visual:needs-approval|visual:failed."),
    ("des", "design-systems", "design:", True,
     "Inspect UI PR #{pr} for design-token drift (Mode 2). Label design:passed|design:changes-requested."),
]

DRY_RUN = False
last_output = {}   # agent name -> (output hash, first seen unchanged at)
notified = set()   # agent names we've already raised a stall alert for


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


def run(cmd, mutate=True, check=True):
    """Run a command in the app repo. Mutating commands are skipped in --dry-run."""
    if mutate and DRY_RUN:
        log("DRY-RUN " + " ".join(cmd))
        return ""
    proc = subprocess.run(cmd, cwd=APP_REPO, capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed ({proc.returncode}): {proc.stderr.strip()}")
    return proc.stdout


def script(name, *args, check=True):
    return run([os.path.join(SCRIPTS, name), *map(str, args)], check=check).strip()


def gh_json(*args):
    return json.loads(run(["gh", *args], mutate=False) or "null")


def labels_of(item):
    return {l["name"] for l in item.get("labels", [])}


def add_labels(kind, num, *labels, remove=()):
    args = ["gh", kind, "edit", str(num)]
    for l in labels:
        args += ["--add-label", l]
    for l in remove:
        args += ["--remove-label", l]
    run(args)


# ---------- herdr ----------

def live_agents():
    out = run(["herdr", "agent", "list"], mutate=False)
    agents = json.loads(out).get("result", {}).get("agents", [])
    return {a["name"]: a for a in agents if a.get("name")}


def spawn(name, agent, cwd, prompt, *env):
    script("spawn_agent.sh", name, agent, cwd, prompt, *env, check=False)


def close(name):
    out = run(["herdr", "agent", "get", name], mutate=False, check=False)
    try:
        info = json.loads(out).get("result", {})
    except ValueError:
        return
    pane = (info.get("agent") or info).get("pane_id")
    if pane:
        run(["herdr", "workspace", "close", pane.split(":")[0]], check=False)
        log(f"closed {name}")


def prompt(name, text):
    run(["herdr", "agent", "prompt", name, text], check=False)


def count(agents, *prefixes):
    return sum(1 for n in agents if n.startswith(prefixes))


def idle(agent):
    return agent.get("agent_status") in ("idle", "done")


# ---------- reaping & stalls ----------

def worktree_for(name):
    """Map a herdr agent name to its worktree key (see prepare_worktree.sh)."""
    m = re.match(r"^dev-issue-(\d+)$", name)
    if m:
        return f"issue-{m.group(1)}"
    m = re.match(r"^(qa|sec|vis|des|rework)-pr-(\d+)$", name)
    if m:
        role = {"qa": "qa", "sec": "security", "vis": "visual", "des": "design", "rework": "dev"}[m.group(1)]
        return f"pr-{m.group(2)}-{role}"
    return None


def finished(name, prs, issues):
    """True when an idle agent's job is done and its workspace can go."""
    m = re.match(r"^dev-issue-(\d+)$", name)
    if m:
        n = int(m.group(1))
        issue = issues.get(n)
        has_pr = any(p["headRefName"] == f"feature/issue-{n}" for p in prs.values())
        return issue is None or has_pr
    m = re.match(r"^(qa|sec|vis|des)-pr-(\d+)$", name)
    if m:
        pr = prs.get(int(m.group(2)))
        prefix = {"qa": "qa:", "sec": "security:", "vis": "visual:", "des": "design:"}[m.group(1)]
        return pr is None or any(l.startswith(prefix) and l != prefix + "in-progress" for l in labels_of(pr))
    m = re.match(r"^rework-pr-(\d+)$", name)
    if m:
        pr = prs.get(int(m.group(1)))
        return pr is None or "status:blocked" not in labels_of(pr)
    if name.startswith(("review-", "roadmap", "agile-pm", "hitl")):
        return True
    return False  # merge-master and anything unknown stay up


def reap(agents, prs, issues):
    for name, agent in agents.items():
        if not idle(agent) or not finished(name, prs, issues):
            continue
        m = re.match(r"^rework-pr-(\d+)$", name)
        if m and int(m.group(1)) in prs:
            # Rework done: clear the marker so the checks re-run on the new commits.
            add_labels("pr", m.group(1), remove=["rework:in-progress"])
        close(name)
        key = worktree_for(name)
        if key:
            script("cleanup_worktree.sh", key, check=False)
        last_output.pop(name, None)
        notified.discard(name)


def detect_stalls(agents):
    now = time.time()
    for name, agent in agents.items():
        status = agent.get("agent_status")
        if status not in ("working", "blocked"):
            last_output.pop(name, None)
            notified.discard(name)
            continue
        text = run(["herdr", "agent", "read", name, "--source", "recent-unwrapped", "--lines", "40"],
                   mutate=False, check=False)
        digest = hashlib.sha1((status + text).encode()).hexdigest()
        prev = last_output.get(name)
        if not prev or prev[0] != digest:
            last_output[name] = (digest, now)
            continue
        limit = BLOCKED_DIALOG_MINUTES if status == "blocked" else STALL_MINUTES
        if now - prev[1] >= limit * 60 and name not in notified:
            reason = ("Waiting at an approval/question dialog. Open herdr to answer it."
                      if status == "blocked" else f"No terminal progress for {limit} minutes.")
            script("notify_human.sh", "--agent-role", name, "--reason", reason,
                   "--context", text[-1200:], "--options", "Continue,Abort", check=False)
            notified.add(name)


# ---------- dispatchers ----------

def is_rfc(pr):
    files = [f["path"] for f in pr.get("files", [])]
    return "rfc" in labels_of(pr) or (files and all(f.startswith("docs/rfcs/") for f in files))


def touches_ui(pr):
    return any(f["path"].startswith(UI_PATHS) for f in pr.get("files", []))


def dispatch_rfc_reviews(prs):
    for n, pr in prs.items():
        if is_rfc(pr) and not {"rfc:in-review", "rfc:queued"} & labels_of(pr):
            log(f"RFC PR #{n}: launching review committee")
            script("trigger_rfc_swarm.sh", n, check=False)


def dispatch_checks(agents, prs):
    for n, pr in sorted(prs.items()):
        labels = labels_of(pr)
        if is_rfc(pr) or pr.get("isDraft") or "status:pr-review" not in labels:
            continue
        if {"rework:in-progress", "status:blocked"} & labels or set(FAILURE_LABELS) & labels:
            continue
        for short, agent, prefix, ui_only, text in PR_CHECKS:
            name = f"{short}-pr-{n}"
            if name in agents or any(l.startswith(prefix) for l in labels):
                continue
            if ui_only and not touches_ui(pr):
                continue
            cap_ok = count(agents, "qa-pr-") < MAX_QA if short == "qa" else \
                count(agents, "sec-pr-", "vis-pr-", "des-pr-", "review-") < MAX_REVIEWERS
            if not cap_ok:
                continue
            role = {"qa": "qa", "sec": "security", "vis": "visual", "des": "design"}[short]
            wt = script("prepare_worktree.sh", "pr", n, role, check=False) if not DRY_RUN else "/tmp/dry-run"
            if not wt:
                continue
            add_labels("pr", n, prefix + "in-progress")
            spawn(name, agent, wt, text.format(pr=n), f"PR_BRANCH={pr['headRefName']}")
            agents[name] = {"agent_status": "working"}


def dispatch_rework(agents, prs):
    for n, pr in sorted(prs.items()):
        labels = labels_of(pr)
        failed = [l for l in FAILURE_LABELS if l in labels]
        name = f"rework-pr-{n}"
        if not failed or name in agents or {"rework:in-progress", "status:blocked"} & labels:
            continue
        cycles = max([int(l.split(":")[1]) for l in labels if re.match(r"^reworked:\d+$", l)], default=0)
        if cycles >= MAX_REWORK:
            log(f"PR #{n}: rework cap reached, escalating")
            script("escalate.sh", "pr", n, f"Still failing after {cycles} rework cycles: {', '.join(failed)}",
                   check=False)
            continue
        if count(agents, "dev-issue-", "rework-pr-") >= MAX_DEV:
            return
        wt = script("prepare_worktree.sh", "pr", n, "dev", check=False) if not DRY_RUN else "/tmp/dry-run"
        if not wt:
            continue
        # Reset every check so they all re-run once the rework lands.
        stale = [l for l in labels if l.startswith(("qa:", "security:", "visual:", "design:", "reworked:"))]
        stale += [l for l in failed if l not in stale]
        add_labels("pr", n, "rework:in-progress", f"reworked:{cycles + 1}", remove=stale)
        spawn(name, "feature-developer", wt,
              f"PR #{n} failed verification ({', '.join(failed)}). Read the failure comments on the PR, fix the "
              f"branch, run bin/ci, and push with `git push origin HEAD:refs/heads/{pr['headRefName']}`. "
              "Do not open a new PR.",
              f"PR_BRANCH={pr['headRefName']}")
        agents[name] = {"agent_status": "working"}


def dispatch_merge(agents, prs):
    queue = [n for n, pr in prs.items()
             if {"qa:passed", "status:pr-review"} <= labels_of(pr)
             and not {"rework:in-progress", "status:blocked"} & labels_of(pr)
             and not set(FAILURE_LABELS) & labels_of(pr)]
    if not queue:
        return
    mm = agents.get("merge-master")
    if mm is None:
        wt = script("prepare_worktree.sh", "main", "merge-master", check=False) if not DRY_RUN else "/tmp/dry-run"
        if wt:
            spawn("merge-master", "merge-master", wt, "Process the merge queue.")
    elif idle(mm):
        prompt("merge-master", f"Process the merge queue. Eligible PRs: {', '.join(f'#{n}' for n in sorted(queue))}.")


def dispatch_roadmap(agents):
    merged = gh_json("pr", "list", "--state", "merged", "--label", "rfc", "--limit", "50", "--json", "number,labels")
    fresh = [p["number"] for p in merged if "rfc:queued" not in labels_of(p)]
    if not fresh or "roadmap" in agents:
        return
    wt = script("prepare_worktree.sh", "main", "roadmap", "--no-setup", check=False) if not DRY_RUN else "/tmp/dry-run"
    if not wt:
        return
    for n in fresh:
        add_labels("pr", n, "rfc:queued", remove=["rfc:in-review"])
    spawn("roadmap", "roadmap-prioritizer", wt,
          f"New merged RFC PRs: {', '.join(f'#{n}' for n in fresh)}. Score them and the ready backlog against "
          "ROADMAP.md, apply tiers with $AGENT_SCRIPTS/backlog_graph.py --apply-tiers, and hand the top RFC to "
          "$AGENT_SCRIPTS/decompose_rfc.sh.")


def dispatch_hitl(agents, prs, issues):
    pending = [("issue", n) for n, i in issues.items()
               if "status:blocked" in labels_of(i) and "hitl:notified" not in labels_of(i)]
    pending += [("pr", n) for n, p in prs.items()
                if "status:blocked" in labels_of(p) and "hitl:notified" not in labels_of(p)]
    if not pending:
        return
    text = ("These items are blocked and the human hasn't been notified. Synthesize each one and send an alert with "
            "$AGENT_SCRIPTS/notify_human.sh: " + ", ".join(f"{k} #{n}" for k, n in pending))
    hitl = agents.get("hitl")
    if hitl is None:
        wt = script("prepare_worktree.sh", "main", "hitl", "--no-setup", check=False) if not DRY_RUN else "/tmp/dry-run"
        if not wt:
            return
        spawn("hitl", "hitl-dispatcher", wt, text)
    elif idle(hitl):
        prompt("hitl", text)
    else:
        return
    for kind, n in pending:
        add_labels(kind, n, "hitl:notified")


def dispatch_dev(agents):
    slots = MAX_DEV - count(agents, "dev-issue-", "rework-pr-")
    if slots <= 0:
        return
    graph, _ = backlog_graph.report()
    for node in backlog_graph.ready_queue(graph)[:slots]:
        n = node["number"]
        name = f"dev-issue-{n}"
        if name in agents:
            continue
        if DRY_RUN:
            log(f"DRY-RUN claim + spawn {name}")
            continue
        try:
            script("claim_issue.sh", n)
        except RuntimeError as e:
            log(f"skip #{n}: {e}")
            continue
        wt = script("prepare_worktree.sh", "issue", n, check=False)
        if not wt:
            log(f"#{n}: worktree setup failed; leaving it claimed for a human to look at")
            continue
        spawn(name, "feature-developer", wt,
              f"Execute GitHub issue #{n}. Plan first, then implement, verify with bin/ci, and finish with "
              f"$AGENT_SCRIPTS/create_pr.sh {n}.")
        agents[name] = {"agent_status": "working"}


# ---------- main loop ----------

def tick():
    agents = live_agents()
    prs = {p["number"]: p for p in gh_json(
        "pr", "list", "--state", "open", "--limit", "100",
        "--json", "number,title,labels,headRefName,isDraft,files")}
    issues = {i["number"]: i for i in gh_json(
        "issue", "list", "--state", "open", "--limit", "500", "--json", "number,title,labels")}

    reap(agents, prs, issues)
    agents = live_agents()
    detect_stalls(agents)
    dispatch_rfc_reviews(prs)
    dispatch_rework(agents, prs)
    dispatch_checks(agents, prs)
    dispatch_merge(agents, prs)
    dispatch_roadmap(agents)
    dispatch_hitl(agents, prs, issues)
    dispatch_dev(agents)


def main():
    global DRY_RUN
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--once", action="store_true", help="run a single tick and exit")
    parser.add_argument("--dry-run", action="store_true", help="log mutating actions instead of running them")
    parser.add_argument("--interval", type=int, default=45)
    args = parser.parse_args()
    DRY_RUN = args.dry_run

    while True:
        try:
            tick()
        except Exception as e:  # never let one bad tick kill the loop
            log(f"tick failed: {e}")
        if args.once:
            break
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
