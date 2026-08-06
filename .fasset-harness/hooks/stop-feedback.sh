#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/../.." && pwd)
deliver_feedback="$project_root/.fasset-harness/hooks/deliver-feedback.sh"
checks="$project_root/.fasset-harness/feedback/stop.d"
state="$project_root/.fasset-harness/state/optimistic-feedback"
failures="$state/failures"
hook_input=$(cat)

initial_deliver_status=0
if [ -x "$deliver_feedback" ]; then
  if "$deliver_feedback" "$project_root"; then
    initial_deliver_status=0
  else
    initial_deliver_status=$?
  fi
  if [ "$initial_deliver_status" -ne 0 ] && [ "$initial_deliver_status" -ne 2 ]; then
    exit "$initial_deliver_status"
  fi
fi

if [ "$initial_deliver_status" -eq 2 ]; then
  exit 2
fi

if grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true' <<< "$hook_input"; then
  exit 0
fi

mkdir -p "$checks" "$failures"

remove_owner_dir() {
  local owner_dir=${1:?owner directory is required}
  rm -f "$owner_dir/owner" "$owner_dir/rerun"
  rmdir "$owner_dir" 2>/dev/null || true
}

owner_is_active() {
  local owner_dir=${1:?owner directory is required}
  local owner_pid
  owner_pid=$(cat "$owner_dir/owner" 2>/dev/null || true)
  [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null
}

event_coordination=
event_coordination_owner_dir=
event_coordination_owner_name=

acquire_event_coordination() {
  local running_root=${1:?running root is required}
  local event=${2:?event is required}
  local candidate candidate_name existing_name existing_dir
  [ -d "$running_root" ] || return 1
  event_coordination="$running_root/.$event.coordination"
  candidate=$(mktemp -d "$running_root/.$event.coordination-owner.XXXXXX")
  candidate_name=${candidate##*/}
  printf '%s\n' "$$" > "$candidate/owner"

  while :; do
    if ln -s "$candidate_name/owner" "$event_coordination" 2>/dev/null; then
      event_coordination_owner_dir=$candidate
      event_coordination_owner_name="$candidate_name/owner"
      return 0
    fi
    if [ -L "$event_coordination" ]; then
      existing_name=$(readlink "$event_coordination")
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
      rm -f "$event_coordination"
      remove_owner_dir "$existing_dir"
      continue
    fi
    if [ -d "$event_coordination" ]; then
      rmdir "$event_coordination" 2>/dev/null || true
      continue
    fi
    [ -d "$running_root" ] || {
      remove_owner_dir "$candidate"
      return 1
    }
  done
}

release_event_coordination() {
  if [ -n "$event_coordination_owner_name" ] && [ -L "$event_coordination" ] && [ "$(readlink "$event_coordination")" = "$event_coordination_owner_name" ]; then
    rm -f "$event_coordination"
  fi
  if [ -n "$event_coordination_owner_dir" ]; then
    remove_owner_dir "$event_coordination_owner_dir"
  fi
  event_coordination=
  event_coordination_owner_dir=
  event_coordination_owner_name=
}

running_entry_is_active() {
  local running_entry=${1:?running entry is required}
  local event=${running_entry##*/}
  local running_root=${running_entry%/*}
  local owner_name owner_dir owner_pid

  acquire_event_coordination "$running_root" "$event" || return 1

  if [ -d "$running_entry" ] && [ ! -L "$running_entry" ]; then
    rm -f "$running_entry/rerun" "$running_entry/owner"
    rmdir "$running_entry" 2>/dev/null || true
    release_event_coordination
    return 1
  fi
  if [ ! -L "$running_entry" ]; then
    release_event_coordination
    return 1
  fi

  owner_name=$(readlink "$running_entry")
  owner_dir="$running_root/$owner_name"
  owner_pid=$(cat "$owner_dir/owner" 2>/dev/null || true)
  if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
    release_event_coordination
    return 0
  fi

  rm -f "$running_entry"
  remove_owner_dir "$owner_dir"
  release_event_coordination
  return 1
}

non_stop_feedback_is_active() {
  for pending in "$state"/*.pending; do
    [ -e "$pending" ] || continue
    event=${pending##*/}
    [ "$event" = "stop.pending" ] || return 0
  done
  for coordination in "$state/running"/.*.coordination; do
    [ -L "$coordination" ] || [ -d "$coordination" ] || continue
    event=${coordination##*/}
    event=${event#.}
    event=${event%.coordination}
    [ "$event" = "stop" ] && continue
    if acquire_event_coordination "$state/running" "$event"; then
      release_event_coordination
    fi
  done
  for running in "$state/running"/*; do
    [ -d "$running" ] || continue
    event=${running##*/}
    if [ "$event" != "stop" ] && running_entry_is_active "$running"; then
      return 0
    fi
  done
  return 1
}

while non_stop_feedback_is_active; do
  sleep 0.05
done

for check in "$checks"/*; do
  [ -f "$check" ] || continue
  name=$(basename "$check")
  failure="$failures/stop--$name.failure"
  output=$(mktemp "$failures/.stop--$name.output.XXXXXX")
  if [ ! -x "$check" ]; then
    printf 'Stop feedback could not execute %s because it is not executable\n' "$name" > "$output"
    status=126
  else
    status=0
    "$check" > "$output" 2>&1 || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    rm -f "$failure" "$output"
    continue
  fi
  stored=$(mktemp "$failures/.stop--$name.failure.XXXXXX")
  printf 'STOP FEEDBACK: %s failed with status %s\n' "$name" "$status" > "$stored"
  cat "$output" >> "$stored"
    mv "$stored" "$failure"
    rm "$output"
done

stop_deliver_status=0
if [ -x "$deliver_feedback" ]; then
  if "$deliver_feedback" "$project_root"; then
    stop_deliver_status=0
  else
    stop_deliver_status=$?
  fi
fi

if [ "$initial_deliver_status" -eq 2 ] || [ "$stop_deliver_status" -eq 2 ]; then
  exit 2
fi

exit "$stop_deliver_status"
