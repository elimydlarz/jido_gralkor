#!/usr/bin/env bash
set -euo pipefail

project_root=${1:?project root is required}
state="$project_root/.fasset-harness/state/optimistic-feedback"
failures="$state/failures"
lock="$state/delivery.lock"
lock_candidate=''
report=''
claims=''
delivery_committed=0
restore_index=0

if [ ! -d "$failures" ]; then
  exit 0
fi

restore_claim() {
  local claimed="$1"
  local name original restored
  name=${claimed##*/}
  original="$failures/$name"
  if [ ! -e "$original" ]; then
    mv "$claimed" "$original"
    return
  fi

  restore_index=$((restore_index + 1))
  restored="$failures/${name%.failure}--restored-$$-$restore_index.failure"
  while [ -e "$restored" ]; do
    restore_index=$((restore_index + 1))
    restored="$failures/${name%.failure}--restored-$$-$restore_index.failure"
  done
  mv "$claimed" "$restored"
}

restore_claims() {
  local claims_directory="$1"
  local claimed
  [ -d "$claims_directory" ] || return 0
  for claimed in "$claims_directory"/*.failure; do
    [ -f "$claimed" ] || continue
    restore_claim "$claimed"
  done
}

lock_value() {
  local lock_path="$1"
  local line="$2"
  if [ -d "$lock_path" ]; then
    case "$line" in
      1) cat "$lock_path/owner" 2>/dev/null || true ;;
      2) cat "$lock_path/claims" 2>/dev/null || true ;;
    esac
    return
  fi
  sed -n "${line}p" "$lock_path" 2>/dev/null || true
}

remove_stale_lock() {
  local stale="$1"
  local nested_candidate
  if [ -d "$stale" ]; then
    for nested_candidate in "$stale"/delivery.lock.candidate.*; do
      [ -f "$nested_candidate" ] || continue
      rm -f "$nested_candidate"
    done
    rm -f "$stale/claims" "$stale/owner"
    rmdir "$stale" 2>/dev/null || true
    return
  fi
  rm -f "$stale"
}

recover_abandoned_lock() {
  local owner stale abandoned_claims
  owner=$(lock_value "$lock" 1)
  if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
    return 1
  fi

  stale="$state/delivery.lock.recovering.$$"
  if ! mv "$lock" "$stale" 2>/dev/null; then
    return 1
  fi

  abandoned_claims=$(lock_value "$stale" 2)
  if [[ "$abandoned_claims" == "$state"/delivery.claims.* ]] && [ -d "$abandoned_claims" ]; then
    restore_claims "$abandoned_claims"
    rmdir "$abandoned_claims" 2>/dev/null || true
  fi
  remove_stale_lock "$stale"
  return 0
}

claims=$(mktemp -d "$state/delivery.claims.XXXXXX")
lock_candidate=$(mktemp "$state/delivery.lock.candidate.XXXXXX")
printf '%s\n%s\n' "$$" "$claims" > "$lock_candidate"
while true; do
  if [ ! -d "$lock" ] && ln "$lock_candidate" "$lock" 2>/dev/null; then
    break
  fi
  if ! recover_abandoned_lock; then
    rm -f "$lock_candidate"
    rmdir "$claims"
    exit 0
  fi
done
rm -f "$lock_candidate"
lock_candidate=''

release_lock() {
  local owner owned_claims
  owner=$(lock_value "$lock" 1)
  owned_claims=$(lock_value "$lock" 2)
  if [ "$owner" = "$$" ] && [ "$owned_claims" = "$claims" ]; then
    rm -f "$lock"
  fi
}

cleanup_delivery() {
  local status=$?
  trap - EXIT
  if [ "$delivery_committed" -eq 0 ] && [ -n "$claims" ]; then
    restore_claims "$claims"
  fi
  [ -n "$report" ] && rm -f "$report"
  if [ -n "$claims" ] && [ -d "$claims" ]; then
    rmdir "$claims" 2>/dev/null || true
  fi
  [ -n "$lock_candidate" ] && rm -f "$lock_candidate"
  release_lock
  exit "$status"
}
trap cleanup_delivery EXIT

reported=0
report=$(mktemp "$state/delivery.XXXXXX")

for failure in "$failures"/*.failure; do
  [ -f "$failure" ] || continue
  claimed="$claims/${failure##*/}"
  mv "$failure" "$claimed" 2>/dev/null || continue
  reported=1
  printf '%s\n' "---- ${failure##*/} ----" >> "$report"
  if ! cat "$claimed" >> "$report"; then
    exit 1
  fi
  printf '\n' >> "$report"
done

if [ "$reported" -eq 1 ]; then
  if ! cat "$report" >&2; then
    exit 1
  fi
  delivery_committed=1
  rm -f "$claims"/*.failure
  exit 2
fi

delivery_committed=1
