#!/usr/bin/env bash
set -Eeuo pipefail

level="${1:-}"
if [[ -z "$level" || ! "$level" =~ ^(major|minor|patch|current)$ ]]; then
  echo "Usage: ./scripts/publish.sh <major|minor|patch|current>" >&2
  exit 1
fi

project_root="$(pwd)"
mix_file="$project_root/mix.exs"

if [[ -z "${DRY_RUN:-}" ]]; then
  whoami_cmd="${PUBLISH_HEX_WHOAMI_CMD:-mix hex.user whoami}"
  if ! $whoami_cmd </dev/null >/dev/null 2>&1; then
    echo "Error: not logged in to Hex. Run 'mix hex.user auth' first." >&2
    exit 1
  fi
fi

read_version() {
  FILE="$mix_file" node -e '
const fs = require("fs");
const src = fs.readFileSync(process.env.FILE, "utf8");
const m = src.match(/@version\s+"([^"]+)"/);
if (!m) { process.stderr.write("no @version in " + process.env.FILE + "\n"); process.exit(1); }
process.stdout.write(m[1]);
'
}

write_version() {
  FILE="$mix_file" V="$1" node -e '
const fs = require("fs");
const src = fs.readFileSync(process.env.FILE, "utf8");
const next = src.replace(/(@version\s+)"[^"]+"/, (_, p1) => p1 + "\"" + process.env.V + "\"");
fs.writeFileSync(process.env.FILE, next);
'
}

bump_version() {
  OLD="$1" KIND="$2" node -e '
const [maj, min, pat] = process.env.OLD.split(".").map(Number);
const k = process.env.KIND;
let v;
if (k === "major") v = [maj + 1, 0, 0];
else if (k === "minor") v = [maj, min + 1, 0];
else v = [maj, min, pat + 1];
process.stdout.write(v.join("."));
'
}

old_version=$(read_version)

rollback() {
  cd "$project_root"
  echo "Rolling back $mix_file to $old_version..." >&2
  write_version "$old_version"
}

if [[ "$level" != "current" ]]; then
  new_version=$(bump_version "$old_version" "$level")
  write_version "$new_version"
else
  new_version="$old_version"
fi
version="$new_version"

if [[ "$level" == "current" ]]; then
  echo "Publishing current Hex version $version (no bump)"
else
  echo "Bumped $mix_file to $version"
fi

if [[ -z "${DRY_RUN:-}" ]]; then
  publish_cmd="${PUBLISH_HEX_PUBLISH_CMD:-mix hex.publish --yes}"

  [[ "$level" != "current" ]] && trap rollback ERR

  $publish_cmd

  [[ "$level" != "current" ]] && trap - ERR

  if [[ "$level" != "current" ]]; then
    git commit --only "$mix_file" -m "jido-gralkor-v$version" || \
      git diff --quiet HEAD -- "$mix_file"
  fi
  if git rev-parse "jido-gralkor-v$version" >/dev/null 2>&1; then
    echo "Tag jido-gralkor-v$version already exists — skipping"
  else
    git tag "jido-gralkor-v$version"
  fi

  echo "Published jido-gralkor-v$version to Hex — tag created locally. Push manually: git push --follow-tags"
fi
