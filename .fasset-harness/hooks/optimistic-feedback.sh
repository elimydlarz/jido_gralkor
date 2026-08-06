#!/usr/bin/env bash
set -euo pipefail

event=${1-}
project_root=$(cd "$(dirname "$0")/../.." && pwd)
runner="$project_root/.fasset-harness/hooks/run-feedback.sh"
state="$project_root/.fasset-harness/state/optimistic-feedback"
failures="$state/failures"

close_hook_fds() {
  for descriptor_path in /dev/fd/*; do
    descriptor=${descriptor_path##*/}
    case "$descriptor" in
      0|1|2|255|*[!0-9]*) continue ;;
    esac
    eval "exec ${descriptor}>&-" 2>/dev/null || true
  done
}

if [ -z "$event" ]; then
  printf '%s\n' 'feedback event is required' >&2
  exit 2
fi
if [ "$event" = 'stop' ] || [ "$event" = 'Stop' ]; then
  printf '%s\n' 'Non-Stop feedback dispatcher cannot run Stop' >&2
  exit 2
fi
checks="$project_root/.fasset-harness/feedback/$event.d"

if [ ! -d "$checks" ]; then
  printf 'Feedback event has no check directory: %s\n' "$event" >&2
  exit 2
fi

mkdir -p "$failures"

if [ ! -x "$runner" ]; then
  stored=$(mktemp "$failures/.${event}--runner.failure.XXXXXX")
  printf 'OPTIMISTIC FEEDBACK: run-feedback.sh failed with status 126\n' > "$stored"
  printf 'Optimistic feedback could not execute run-feedback.sh because it is not executable\n' >> "$stored"
  mv "$stored" "$failures/$event--runner.failure"
  exit 0
fi

touch "$state/$event.pending"
(
  close_hook_fds
  runner_status=0
  nohup "$runner" "$event" </dev/null >/dev/null 2>&1 || runner_status=$?
  if [ "$runner_status" -ne 0 ]; then
    stored=$(mktemp "$failures/.${event}--runner.failure.XXXXXX")
    printf 'OPTIMISTIC FEEDBACK: run-feedback.sh failed with status %s\n' "$runner_status" > "$stored"
    printf 'Optimistic feedback could not start run-feedback.sh for %s\n' "$event" >> "$stored"
    mv "$stored" "$failures/$event--runner.failure"
    rm -f "$state/$event.pending"
  fi
) </dev/null >/dev/null 2>&1 &
exit 0
