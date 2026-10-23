#!/bin/bash
# Survey outdated and vulnerable dependencies: gems, importmap pins, Ruby/Node
# pins, and the playwright npm/gem version pairing. Writes tmp/deps/report.md.
# Exit 0 = nothing to do, 1 = updates or advisories found.
#
# Usage: deps_survey.sh   (run from an app worktree)
source "$(dirname "$0")/lib/common.sh"

out="tmp/deps"
mkdir -p "$out"
report="$out/report.md"
action=0

{
  echo "# Dependency survey — $(date +%F)"
  echo
  echo "## Security advisories"
  if bin/bundler-audit check --update >"$out/bundler-audit.log" 2>&1; then
    echo "- bundler-audit: clean"
  else
    echo "- **bundler-audit:**"; sed 's/^/    /' "$out/bundler-audit.log"; action=1
  fi
  if bin/importmap audit >"$out/importmap-audit.log" 2>&1; then
    echo "- importmap audit: clean"
  else
    echo "- **importmap audit:**"; sed 's/^/    /' "$out/importmap-audit.log"; action=1
  fi

  echo
  echo "## Outdated gems (direct dependencies)"
  # bundle outdated exits 1 when anything is outdated.
  bundle outdated --only-explicit --parseable 2>/dev/null >"$out/gems.txt" || true
  if [[ -s $out/gems.txt ]]; then
    echo "| Gem | Current | Latest | Bump |"
    echo "| --- | --- | --- | --- |"
    while IFS= read -r line; do
      gem=${line%% *}
      newest=$(sed -E 's/.*newest ([^,)]+).*/\1/' <<<"$line")
      installed=$(sed -E 's/.*installed ([^,)]+).*/\1/' <<<"$line")
      if [[ ${installed%%.*} != "${newest%%.*}" ]]; then bump=major
      elif [[ $(cut -d. -f2 <<<"$installed") != "$(cut -d. -f2 <<<"$newest")" ]]; then bump=minor
      else bump=patch; fi
      echo "| $gem | $installed | $newest | $bump |"
    done <"$out/gems.txt"
    action=1
  else
    echo "All direct gems are current."
  fi

  echo
  echo "## Outdated importmap pins"
  if bin/importmap outdated >"$out/importmap-outdated.log" 2>&1; then
    echo "All pins are current."
  else
    sed 's/^/    /' "$out/importmap-outdated.log"; action=1
  fi

  echo
  echo "## Toolchain"
  echo "- Ruby pinned: $(cat .ruby-version 2>/dev/null || echo '?')"
  echo "- mise.toml: $(grep -E '^(ruby|node)' mise.toml 2>/dev/null | tr '\n' ' ')"
  gem_pw=$(bundle exec ruby -e 'print Gem.loaded_specs["playwright-ruby-client"]&.version' 2>/dev/null || true)
  npm_pw=$(node -p 'require("./package.json").dependencies?.playwright || require("./package.json").devDependencies?.playwright' 2>/dev/null || true)
  echo "- playwright-ruby-client gem: ${gem_pw:-?} / playwright npm: ${npm_pw:-?}"
  if [[ -n $gem_pw && -n $npm_pw && ${npm_pw//[^0-9.]/} != "$gem_pw"* ]]; then
    echo "  - **Mismatch:** keep these on matching versions."; action=1
  fi
} >"$report"

cat "$report"
exit $action
