#!/bin/sh
# Spec check: runs the Crystal spec suite under spec/.
#
# This is the primary "check the spec" hook from issue #1: it executes every
# example in spec/aptok_spec.cr and fails if any example fails or errors.
set -eu

. "$(dirname -- "$0")/lib.sh"

require_cmd crystal "Install Crystal: https://crystal-lang.org/install/" || exit 127

run_step "crystal spec" \
  crystal spec
