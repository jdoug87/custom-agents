# My Custom Agents

A reusable team of Claude Code agents for running a Rails app's delivery pipeline: RFCs and planning, parallel feature development and QA, a single merge gate, release, SRE, and human-in-the-loop alerts over Telegram. The agents run in [herdr](https://herdr.dev) panes and coordinate through GitHub labels.

This repo holds the originals. You install them into a **target repo** (your app), and they run from there.

## Install into a target repo

```bash
./install.sh ~/Projects/my-app
```

| From this repo | Into the target repo |
| --- | --- |
| `agents/*.md` | `.claude/agents/` |
| `scripts/` | `.claude/scripts/` (exact mirror) |
| `templates/*.md` | `docs/templates/` |

- These are copies, not symlinks. **Commit them in the target repo**, because every agent works in a fresh git worktree and only committed files show up there.
- Edit agents and scripts **here**, then re-run `install.sh` on each target. Run `./install.sh <target> --check` to see whether a target has drifted.
- Other files in the target's `.claude/agents/` and `docs/templates/` are left alone. `.claude/scripts/` is mirrored exactly.
- Once installed, the scripts find the target's main checkout on their own, even from inside a worktree.

## What the target repo needs

The agents assume a Rails app on the omakase stack: Minitest, Capybara/Playwright system tests, Hotwire, Tailwind, Kamal, and `bin/ci`.

1. **`AGENTS.md`** at the root, describing the stack, commands, and conventions. Every agent reads it.
2. **Per-worktree databases.** Append `WORKTREE_DB_SUFFIX` to the development and test database names in `config/database.yml`, so parallel agents don't share a database:
   ```yaml
   development:
     database: myapp_development<%= ENV["WORKTREE_DB_SUFFIX"] %>
   test:
     database: myapp_test<%= ENV["WORKTREE_DB_SUFFIX"] %>
   ```
3. **GitHub labels:** run `.claude/scripts/setup_labels.sh` once from the target repo.
4. **Telegram (optional, for phone alerts):** create a bot with @BotFather and export `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`. You can also set `TELEGRAM_ALLOWED_USER_IDS`.
5. **Staging (optional):** add `config/deploy.staging.yml` and export `STAGING_URL` and `PRODUCTION_URL`.
6. **Tools:** `gh` (authenticated), `herdr`, `jq`, and `claude`. Optional extras: `brew install gitleaks imagemagick ffmpeg webp`.

`install.sh` warns you about missing pieces from 1 and 2.

## Running it

From the target repo:

```bash
python3 .claude/scripts/hitl_webhook.py                    # Telegram replies → agent panes
python3 .claude/scripts/orchestrator.py --once --dry-run   # see what it would do
python3 .claude/scripts/orchestrator.py                    # the dispatcher loop
```

Start new work by talking to the RFC author:

```bash
export AGENT_SCRIPTS=$PWD/.claude/scripts && claude --agent rfc-author "I want to add ..."
```

Worktrees are created next to the target, in `<target>-worktrees/`. Set `WORKTREE_ROOT` to change that.

## The agents

| Stage | Agents |
| --- | --- |
| Planning | `rfc-author`, `security-reviewer`, `perf-reviewer`, `dx-reviewer`, `roadmap-prioritizer`, `agile-pm` |
| Building | `orchestrator-dispatcher`, `feature-developer`, `design-systems`, `asset-generator` |
| Verifying | `qa-tester`, `security-auditor`, `visual-regression` |
| Shipping | `merge-master`, `release-engineer`, `technical-writer` |
| Operating | `sre-monitor`, `dependency-maintainer`, `hitl-dispatcher` |

See [scripts/README.md](scripts/README.md) for each script and the label flow.
