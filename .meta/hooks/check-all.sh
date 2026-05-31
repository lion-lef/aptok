#!/bin/sh
# Run every Aptok spec-check hook in order and report a combined result.
#
# Order: format (style) -> build (type check) -> spec (behaviour). The build and
# spec steps are hard failures; the format step honours APTOK_STRICT_FORMAT.
#
# Usage:
#   .meta/hooks/check-all.sh
#   APTOK_STRICT_FORMAT=1 .meta/hooks/check-all.sh   # enforce formatting too
set -eu

hooks_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$hooks_dir/lib.sh"

status=0

for hook in check-format.sh check-build.sh check-spec.sh; do
  if ! sh "$hooks_dir/$hook"; then
    status=1
  fi
  printf '\n'
done

if [ "$status" -eq 0 ]; then
  ok "all spec checks passed"
else
  fail "one or more spec checks failed"
fi

exit "$status"
