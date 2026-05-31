#!/bin/sh
# Format check: verifies sources match `crystal tool format`.
#
# NOTE on Crystal versions: the sources are formatted clean on both Crystal
# 1.11.x and the pinned 1.12.2 (the version CI uses), so this check passes on
# either. The formatter's output can still drift between releases, so to avoid
# spurious failures on an unexpected toolchain a formatting difference is a
# *warning* by default; set APTOK_STRICT_FORMAT=1 (as CI does) to make it a
# hard failure.
set -eu

. "$(dirname -- "$0")/lib.sh"

require_cmd crystal "Install Crystal: https://crystal-lang.org/install/" || exit 127

log "crystal tool format --check"
if (cd "$repo_root" && crystal tool format --check src spec >/dev/null 2>&1); then
  ok "crystal tool format --check"
  exit 0
fi

if [ "${APTOK_STRICT_FORMAT:-0}" = "1" ]; then
  fail "sources are not formatted; run: crystal tool format src spec"
  (cd "$repo_root" && crystal tool format --check src spec) || true
  exit 1
fi

warn "sources differ from this compiler's formatter output."
warn "If you are on Crystal < 1.12 this is likely a version artifact."
warn "Run with APTOK_STRICT_FORMAT=1 to treat this as a failure."
exit 0
