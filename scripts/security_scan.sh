#!/bin/bash
# Pre-merge security scan for a PR: new Brakeman warnings vs main, dependency
# advisories, and a secret scan of the PR's commits. Writes a Markdown report.
# Exit 0 = clean, 1 = findings.
#
# Usage: security_scan.sh <PR_NUMBER>   (run from a worktree of the PR head)
source "$(dirname "$0")/lib/common.sh"
require git jq

[[ $# -eq 1 && $1 =~ ^[0-9]+$ ]] || die "usage: $(basename "$0") <PR_NUMBER>"
pr=$1
out="tmp/security"
mkdir -p "$out"
report="$out/report.md"
findings=0

git fetch -q origin main
base=$(git merge-base origin/main HEAD)

# Brakeman: compare against the merge base so only new warnings count.
base_dir=$(mktemp -d)
trap 'git worktree remove --force "$base_dir" >/dev/null 2>&1 || true' EXIT
git worktree add -q --detach "$base_dir" "$base"
bin/brakeman --quiet --no-pager --format json --output "$out/brakeman-base.json" "$base_dir" || true
bin/brakeman --quiet --no-pager --format json --output "$out/brakeman.json" \
  --compare "$out/brakeman-base.json" . || true
new_warnings=$(jq '.new | length' "$out/brakeman.json" 2>/dev/null || echo "?")

{
  echo "## Security Scan — PR #$pr"
  echo
  echo "### Brakeman (new vs main): $new_warnings"
  jq -r '.new[]? | "- **\(.confidence)** \(.warning_type) — `\(.file):\(.line)` — \(.message)"' "$out/brakeman.json" 2>/dev/null
} >"$report"
[[ $new_warnings == 0 ]] || findings=1

echo -e "\n### Dependency advisories" >>"$report"
if bin/bundler-audit check --update >"$out/bundler-audit.log" 2>&1; then
  echo "- bundler-audit: clean" >>"$report"
else
  echo "- bundler-audit: **advisories found** (see \`$out/bundler-audit.log\`)" >>"$report"; findings=1
fi
if bin/importmap audit >"$out/importmap-audit.log" 2>&1; then
  echo "- importmap audit: clean" >>"$report"
else
  echo "- importmap audit: **advisories found** (see \`$out/importmap-audit.log\`)" >>"$report"; findings=1
fi

echo -e "\n### Secrets" >>"$report"
if git diff --name-only "$base"..HEAD | grep -qE '(^|/)(\.env[^/]*|config/master\.key|config/credentials/.*\.key|\.kamal/secrets.*)$'; then
  echo "- **Sensitive file committed:** $(git diff --name-only "$base"..HEAD | grep -E '\.env|master\.key|\.key$|\.kamal/secrets' | tr '\n' ' ')" >>"$report"
  findings=1
fi
if command -v gitleaks >/dev/null 2>&1; then
  if gitleaks git --log-opts="$base..HEAD" --redact --no-banner --report-path "$out/gitleaks.json" . >/dev/null 2>&1; then
    echo "- gitleaks: clean" >>"$report"
  else
    echo "- gitleaks: **possible secrets** (values redacted; see \`$out/gitleaks.json\`)" >>"$report"; findings=1
  fi
else
  echo "- gitleaks not installed; only the sensitive-filename check ran (\`brew install gitleaks\`)" >>"$report"
fi

cat "$report"
exit $findings
