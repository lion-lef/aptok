#!/bin/sh
# Format check: verifies sources match `crystal tool format`.
#
# NOTE on Crystal versions: the formatter's output changed across releases
# (for example, trailing commas in multi-line argument lists are kept by
# Crystal >= 1.12 but stripped by older versions). shard.yml pins
# `crystal >= 1.12.0`, so this check is authoritative only on a matching
# toolchain. To avoid spurious failures for contributors on an older compiler,
# a formatting difference is a *warning* by default; set APTORK_STRICT_FORMAT=1
# (as CI does) to make it a hard failure.
set -eu

. "$(dirname -- "$0")/lib.sh"

require_cmd crystal "Install Crystal: https://crystal-lang.org/install/" || exit 127

log "crystal tool format --check"
if (cd "$repo_root" && crystal tool format --check src spec >/dev/null 2>&1); then
  ok "crystal tool format --check"
  exit 0
fi

if [ "${APTORK_STRICT_FORMAT:-0}" = "1" ]; then
  fail "sources are not formatted; run: crystal tool format src spec"
  (cd "$repo_root" && crystal tool format --check src spec) || true
  exit 1
fi

warn "sources differ from this compiler's formatter output."
warn "If you are on Crystal < 1.12 this is likely a version artifact."
warn "Run with APTORK_STRICT_FORMAT=1 to treat this as a failure."
exit 0
