#!/bin/sh
# Build check: ensures the Aptok library compiles cleanly.
#
# A green build is the most basic guarantee that the spec (the public API the
# tests exercise) is self-consistent. We compile the entry point without
# producing an artifact so the check stays fast.
set -eu

. "$(dirname -- "$0")/lib.sh"

require_cmd crystal "Install Crystal: https://crystal-lang.org/install/" || exit 127

# `build --no-codegen` type-checks the whole program without emitting a binary,
# which is faster than a full build and enough to catch compile errors.
run_step "crystal build (type check)" \
  crystal build src/aptok.cr --no-codegen
