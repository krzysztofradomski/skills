#!/usr/bin/env bash
# Builds site/agent-skills/ payloads and site/.well-known/agent-skills/index.json
# from the skill folders at the repo root, per the discovery-index RFC
# (schemas.agentskills.io/discovery/0.2.0). Re-run after any change under a skill
# folder and before deploying site/ — the digests must match what site/ serves.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

domain="https://ai-skills.radomski.dev"
out_dir="site/agent-skills"
index_dir="site/.well-known/agent-skills"

rm -rf "$out_dir"
mkdir -p "$out_dir" "$index_dir"

entries=()

for skill_dir in */; do
  skill_dir="${skill_dir%/}"
  [ -f "$skill_dir/SKILL.md" ] || continue

  name="$skill_dir"
  if ! [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "warning: skipping '$name' — not a valid skill name (lowercase, digits, single dashes)" >&2
    continue
  fi

  description="$(sed -n 's/^description: *//p' "$skill_dir/SKILL.md" | head -1)"
  description="${description%\'}"
  description="${description#\'}"

  # A skill is single-file only if SKILL.md is the sole file in its folder,
  # ignoring build artifacts that should never ship (bytecode caches, OS cruft).
  file_count="$(cd "$skill_dir" && find . -type f \
    -not -path '*/__pycache__/*' -not -name '*.pyc' -not -name '*.pyo' -not -name '.DS_Store' \
    | wc -l | tr -d ' ')"

  if [ "$file_count" -eq 1 ]; then
    type="skill-md"
    url="$domain/agent-skills/$name/SKILL.md"
    mkdir -p "$out_dir/$name"
    cp "$skill_dir/SKILL.md" "$out_dir/$name/SKILL.md"
    digest="sha256:$(sha256sum "$out_dir/$name/SKILL.md" | cut -d' ' -f1)"
  else
    type="archive"
    url="$domain/agent-skills/$name.tar.gz"
    archive="$out_dir/$name.tar.gz"
    members="$(cd "$skill_dir" && find . -mindepth 1 -maxdepth 1 -printf '%P\n' | sort)"
    tar -C "$skill_dir" \
      --sort=name --owner=0 --group=0 --numeric-owner --mtime='UTC 2020-01-01' \
      --exclude='__pycache__' --exclude='*.pyc' --exclude='*.pyo' --exclude='.DS_Store' \
      -cf - $members | gzip -n > "$archive"
    digest="sha256:$(sha256sum "$archive" | cut -d' ' -f1)"
  fi

  entries+=("$(printf '    {\n      "name": "%s",\n      "description": %s,\n      "type": "%s",\n      "url": "%s",\n      "digest": "%s"\n    }' \
    "$name" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$description")" "$type" "$url" "$digest")")
done

{
  echo '{'
  echo '  "$schema": "https://schemas.agentskills.io/discovery/0.2.0/schema.json",'
  echo '  "skills": ['
  IFS=$'\n'
  first=1
  for e in "${entries[@]}"; do
    [ "$first" -eq 1 ] || echo ','
    printf '%s' "$e"
    first=0
  done
  echo
  echo '  ]'
  echo '}'
} > "$index_dir/index.json"

echo "wrote $index_dir/index.json (${#entries[@]} skill(s))"
