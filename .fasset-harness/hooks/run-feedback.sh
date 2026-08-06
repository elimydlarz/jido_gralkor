#!/usr/bin/env bash
set -euo pipefail

event=${1:?feedback event is required}
project_root=$(cd "$(dirname "$0")/../.." && pwd)
checks="$project_root/.fasset-harness/feedback/$event.d"
state="$project_root/.fasset-harness/state/optimistic-feedback"
failures="$state/failures"
running_root="$state/running"
running="$running_root/$event"
coordination="$running_root/.$event.coordination"

if [ ! -d "$checks" ]; then
  printf 'Feedback event has no check directory: %s\n' "$event" >&2
  exit 2
fi

mkdir -p "$failures" "$running_root"

owner_is_active() {
  local owner_dir=${1:?owner directory is required}
  local owner_pid
  owner_pid=$(cat "$owner_dir/owner" 2>/dev/null || true)
  [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null
}

remove_owner_dir() {
  local owner_dir=${1:?owner directory is required}
  rm -f "$owner_dir/owner" "$owner_dir/rerun"
  rmdir "$owner_dir" 2>/dev/null || true
}

coordination_owner_dir=
coordination_owner_name=
coordination_held=false

acquire_coordination() {
  local candidate candidate_name existing_name existing_dir
  [ -d "$running_root" ] || return 1
  candidate=$(mktemp -d "$running_root/.$event.coordination-owner.XXXXXX")
  candidate_name=${candidate##*/}
  printf '%s\n' "$$" > "$candidate/owner"

  while :; do
    if ln -s "$candidate_name/owner" "$coordination" 2>/dev/null; then
      coordination_owner_dir=$candidate
      coordination_owner_name="$candidate_name/owner"
      coordination_held=true
      return 0
    fi
    if [ -L "$coordination" ]; then
      existing_name=$(readlink "$coordination")
      existing_dir=${existing_name%/owner}
      existing_dir="$running_root/$existing_dir"
      if owner_is_active "$existing_dir"; then
        [ -d "$running_root" ] || {
          remove_owner_dir "$candidate"
          return 1
        }
        sleep 0.01
        continue
      fi
      rm -f "$coordination"
      remove_owner_dir "$existing_dir"
      continue
    fi
    if [ -d "$coordination" ]; then
      rmdir "$coordination" 2>/dev/null || true
      continue
    fi
    [ -d "$running_root" ] || {
      remove_owner_dir "$candidate"
      return 1
    }
  done
}

release_coordination() {
  if [ -n "$coordination_owner_name" ] && [ -L "$coordination" ] && [ "$(readlink "$coordination")" = "$coordination_owner_name" ]; then
    rm -f "$coordination"
  fi
  if [ -n "$coordination_owner_dir" ]; then
    remove_owner_dir "$coordination_owner_dir"
  fi
  coordination_owner_dir=
  coordination_owner_name=
  coordination_held=false
}

owned_dir=$(mktemp -d "$running_root/.$event.owner.XXXXXX")
owned_name=${owned_dir##*/}
printf '%s\n' "$$" > "$owned_dir/owner"
owns_running=false

release_owned_running() {
  if [ "$owns_running" = true ] && { [ "$coordination_held" = true ] || acquire_coordination; }; then
    if [ -L "$running" ] && [ "$(readlink "$running")" = "$owned_name" ]; then
      rm -f "$running"
    fi
    release_coordination
  fi
  remove_owner_dir "$owned_dir"
}

trap release_owned_running EXIT
trap 'exit 0' INT TERM

while :; do
  acquire_coordination || {
    trap - EXIT INT TERM
    exit 0
  }

  if [ -L "$running" ]; then
    existing_name=$(readlink "$running")
    existing_dir="$running_root/$existing_name"
    if owner_is_active "$existing_dir"; then
      if touch "$existing_dir/rerun" 2>/dev/null; then
        rm -f "$state/$event.pending"
        release_coordination
        trap - EXIT INT TERM
        remove_owner_dir "$owned_dir"
        exit 0
      fi
    else
      rm -f "$running"
      remove_owner_dir "$existing_dir"
    fi
    release_coordination
    continue
  fi

  if [ -d "$running" ]; then
    rm -f "$running/rerun" "$running/owner"
    rmdir "$running" 2>/dev/null || true
    release_coordination
    continue
  fi

  ln -s "$owned_name" "$running"
  owns_running=true
  rm -f "$state/$event.pending"
  release_coordination
  break
done

while :; do
  rm -f "$owned_dir/rerun"
  for check in "$checks"/*; do
    [ -f "$check" ] || continue
    name=$(basename "$check")
    failure="$failures/$event--$name.failure"
    output=$(mktemp "$failures/.$event--$name.output.XXXXXX")
    if [ ! -x "$check" ]; then
      printf 'Optimistic feedback could not execute %s because it is not executable\n' "$name" > "$output"
      status=126
    else
      status=0
      "$check" > "$output" 2>&1 || status=$?
    fi
    if [ "$status" -eq 0 ]; then
      rm -f "$failure" "$output"
      continue
    fi
    stored=$(mktemp "$failures/.$event--$name.failure.XXXXXX")
    printf 'OPTIMISTIC FEEDBACK: %s failed with status %s\n' "$name" "$status" > "$stored"
    cat "$output" >> "$stored"
    mv "$stored" "$failure"
    rm "$output"
  done

  acquire_coordination || {
    trap - EXIT INT TERM
    exit 0
  }
  if [ ! -L "$running" ] || [ "$(readlink "$running")" != "$owned_name" ]; then
    release_coordination
    owns_running=false
    trap - EXIT INT TERM
    remove_owner_dir "$owned_dir"
    exit 0
  fi
  if [ -e "$owned_dir/rerun" ]; then
    rm -f "$owned_dir/rerun"
    release_coordination
    continue
  fi

  rm -f "$running"
  owns_running=false
  release_coordination
  trap - EXIT INT TERM
  remove_owner_dir "$owned_dir"
  exit 0
done
