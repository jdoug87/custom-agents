# Repository Conventions for AI Agents

<!-- Seeded by custom-agents/install.sh. Fill in the TODOs and commit; every agent reads this file. -->

## Core Stack

- Ruby on Rails (omakase): TODO Ruby/Rails versions, database
- Frontend: Hotwire (Turbo + Stimulus), Tailwind, importmap
- Tests: Minitest, with Capybara/Playwright system tests in `test/system/`
- Deploys: Kamal (`config/deploy.yml`, plus `config/deploy.staging.yml` if you use staging)

## Build & Test Commands

- Setup: `bin/setup`
- Dev server: `bin/dev`
- Targeted tests: `bin/rails test test/models/foo_test.rb`, `bin/rails test:system`
- Full CI (lint, security scans, tests): `bin/ci`
- Migrations: `bin/rails g migration <Name>`, then `bin/rails db:migrate`

## Docs Layout

- `docs/rfcs/`: technical RFCs (rfc-author)
- `docs/plans/`: per-issue implementation plans (feature-developer)
- `docs/adr/`, `docs/architecture/`, `docs/api/`: decisions and living docs (technical-writer)
- `docs/incidents/`: post-mortems (sre-monitor)
- `docs/security/audits/`: audit reports (security-auditor)
- `docs/templates/`: story, epic, and RFC templates (installed by custom-agents)

## Rules & Constraints

- TODO: project-specific conventions (naming, service objects, authorization, etc.)
- Never commit secrets, `.env` files, or `config/master.key`; use Rails credentials.
- Never push to `main`; work on a branch and open a PR.
