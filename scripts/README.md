# Agent Pipeline Scripts

Deterministic helpers the agents (and the orchestrator) call so they don't have to improvise long shell sequences. All bash scripts source `lib/common.sh`, run on macOS's stock bash 3.2, and use `gh` against the app repo.

Installed into a target repo at `.claude/scripts/` by `install.sh` in the custom-agents repo. See that repo's README for installing and setting up a target.

```bash
python3 .claude/scripts/hitl_webhook.py                    # Telegram replies → agent panes (long-polling, no tunnel)
python3 .claude/scripts/orchestrator.py --once --dry-run   # see what it would do
python3 .claude/scripts/orchestrator.py                    # the dispatcher loop
```

## Environment

| Variable | Default | Used for |
| --- | --- | --- |
| `APP_REPO` | auto-detected | Main checkout of the target repo |
| `WORKTREE_ROOT` | `<target>-worktrees` next to the target | Per-agent git worktrees |
| `CLAUDE_ARGS` | `--permission-mode auto` | Extra args for spawned `claude` agents |
| `MAX_DEV` / `MAX_QA` / `MAX_REVIEWERS` | 6 / 4 / 6 | Concurrency caps |
| `MAX_REWORK` / `STALL_MINUTES` | 2 / 45 | Rework cap, stall alert threshold |
| `AGENT_SCRIPTS`, `AGENT_NAME`, `PR_BRANCH`, `WORKTREE_DB_SUFFIX` | set by `spawn_agent` | Inside agent panes |

## Scripts by agent

| Script | Used by | What it does |
| --- | --- | --- |
| `lib/common.sh` | all | Logging, label groups, blocker parsing, `spawn_agent`, `close_agent` |
| `setup_labels.sh` | you | Create/update all pipeline labels |
| `spawn_agent.sh` | orchestrator, any | Launch an agent in its own herdr workspace with a prompt |
| `set_status.sh` | all | Set a label and drop the ones it replaces (`qa:*`, `status:*`, …) |
| `escalate.sh` | all | Label blocked, comment with logs, send a HITL alert |
| `notify_human.sh` | escalate, hitl-dispatcher, orchestrator | Telegram alert with buttons (herdr notification fallback) |
| `hitl_webhook.py` | runs standalone | Routes Telegram replies/button taps to `herdr agent prompt` |
| `orchestrator.py` | runs standalone | The dispatcher loop (see its docstring for the stage map) |
| `prepare_worktree.sh` | orchestrator | Issue/PR/main worktrees + `bin/setup` with per-worktree DBs |
| `cleanup_worktree.sh` | orchestrator | Remove a worktree and its databases (refuses dirty/unpushed) |
| `backlog_graph.py` | orchestrator, roadmap, agile-pm | Blocked-By graph, cycles, tiers, ready queue, `--apply-tiers` |
| `new_rfc.sh` | rfc-author | Next RFC number from `docs/templates/rfc-template.md` |
| `trigger_rfc_swarm.sh` | orchestrator | Security/perf/dx reviewers on an RFC PR |
| `decompose_rfc.sh` | roadmap | Hand a merged RFC to the single agile-pm |
| `claim_issue.sh` | orchestrator, feature-developer | Verify ready + unblocked, mark in-progress |
| `create_pr.sh` | feature-developer | Push and open the PR with RFC lineage and plan link |
| `run_qa.sh` | qa-tester | Targeted tests + `bin/ci`, flake re-run, logs to `tmp/qa/` |
| `security_scan.sh` | security-auditor | New Brakeman warnings vs main, audits, secret scan |
| `visual_diff.sh` | visual-regression | ImageMagick screenshot diffs vs baselines |
| `record_walkthrough.sh` | visual-regression | Playwright `.webm` → MP4 with optional `say` voiceover |
| `optimize_assets.sh` | asset-generator, design-systems | SVGO, WebP, size budgets |
| `process_merge_queue.sh` | merge-master | Pick next eligible PR, stage integration branch |
| `finalize_merge.sh` | merge-master | Schema regen, `bin/ci`, squash-merge, issue → waiting-for-deploy |
| `deploy.sh` | release-engineer | CI-green gate, `kamal deploy`, smoke checks |
| `smoke_check.sh` | release-engineer, rollback | `/up`, key pages, Solid Queue heartbeats |
| `rollback_deployment.sh` | release-engineer, sre-monitor | `kamal rollback` to the previous release tag's SHA |
| `incident_context.sh` | sre-monitor | Deployed version, recent merges, filtered error logs |
| `sre_toggle_flag.sh` | sre-monitor | PostHog flag on/off (needs a flag provider first) |
| `deps_survey.sh` | dependency-maintainer | Outdated/vulnerable gems and pins, playwright pairing |
| `release_changes.sh` | technical-writer, release-engineer | Merged PRs grouped into changelog sections |

## Label flow

```
status:backlog → status:ready-for-agent → in-progress → status:pr-review
  → (qa:* security:* visual:* design:* in parallel) → qa:passed → merge
  → waiting-for-deploy → deployed → status:done
Any failure → rework:in-progress (max MAX_REWORK) → status:blocked + hitl:notified
```
