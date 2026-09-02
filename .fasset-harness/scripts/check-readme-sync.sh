#!/usr/bin/env bash
set -euo pipefail
root=$(git rev-parse --show-toplevel)
cd "$root"
state=".fasset-harness/state/readme-sync"
baseline="$state/baseline"
mkdir -p "$state"

surface_files=(
  mix.exs
  priv/python/pyproject.toml
  .env.example
  config/config.exs
  lib/gralkor/application.ex
  lib/gralkor/client.ex
  lib/gralkor/client/native.ex
  lib/gralkor/config.ex
  lib/gralkor/graphiti_pool.ex
  lib/gralkor/ingest.ex
  lib/gralkor/ingested_representation.ex
  lib/gralkor/search.ex
  lib/gralkor/destination/storage.ex
  lib/gralkor/destination/storage/graphiti.ex
  lib/gralkor/destination/storage/in_memory.ex
  lib/gralkor/lens.ex
  lib/gralkor/lens/ingestion.ex
  lib/gralkor/lens/ingestion/store.ex
  lib/gralkor/lens/store.ex
  lib/gralkor/artefact.ex
  lib/gralkor/artefact/return_handler.ex
  lib/gralkor/reflection.ex
  lib/gralkor/reflection/chain_of_thought.ex
  lib/gralkor/reflection/registry.ex
  lib/gralkor/reflection/runner.ex
  lib/gralkor/reflection/scheduler.ex
  lib/gralkor/reflection/store.ex
  lib/gralkor/ontology.ex
  lib/gralkor/python.ex
  priv/reflections/generalisations.yaml
  priv/reflections/erl.yaml
  lib/jido_gralkor/plugin.ex
  lib/jido_gralkor/re_act.ex
  lib/jido_gralkor/lifecycle.ex
  lib/jido_gralkor/context_rotator.ex
  lib/jido_gralkor/actions/memory_search.ex
  lib/jido_gralkor/actions/memory_add.ex
  lib/jido_gralkor/actions/memory_build_indices.ex
  lib/jido_gralkor/actions/memory_build_communities.ex
  .agents/skills/publish/SKILL.md
)
files=("README.md" "${surface_files[@]}")

hash_file() { [ -f "$1" ] && sha256sum "$1" | cut -d' ' -f1 || printf 'absent'; }

current=$(mktemp)
for f in "${files[@]}"; do printf '%s %s\n' "$f" "$(hash_file "$f")" >> "$current"; done

if [ "${1:-}" = "--rebaseline" ]; then
  mv "$current" "$baseline"
  exit 0
fi

if [ ! -f "$baseline" ]; then
  mv "$current" "$baseline"
  exit 0
fi

changed_surface=()
readme_changed=0
while IFS=' ' read -r f hash; do
  old=$(awk -v f="$f" '$1==f {print $2}' "$baseline")
  if [ "$f" = "README.md" ]; then
    [ "$hash" != "$old" ] && readme_changed=1
  elif [ "$hash" != "$old" ]; then
    changed_surface+=("$f")
  fi
done < "$current"

if [ "${#changed_surface[@]}" -eq 0 ] || [ "$readme_changed" -eq 1 ]; then
  mv "$current" "$baseline"
  exit 0
fi

printf 'README.md is unchanged but these surface files changed: %s\n' "${changed_surface[*]}"
printf 'Reconcile README.md. If consumer-facing installation, configuration, and usage are unchanged, run .fasset-harness/scripts/check-readme-sync.sh --rebaseline.\n'
rm -f "$current"
exit 1
