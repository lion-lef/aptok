# Aptork spec-check hooks

Shell hooks that **check the spec** — they verify the library still builds and
that every example in `spec/` passes. They are plain POSIX `sh` scripts so they
run identically on a developer machine, in a git hook, or in CI.

## Scripts

| Script | What it checks | Failure mode |
| --- | --- | --- |
| `check-format.sh` | `crystal tool format --check src spec` | warning by default, hard failure with `APTORK_STRICT_FORMAT=1` |
| `check-build.sh` | `crystal build src/aptork.cr --no-codegen` (type check) | hard failure |
| `check-spec.sh` | `crystal spec` (the full example suite) | hard failure |
| `check-all.sh` | runs all three in order | non-zero if any hard check fails |
| `lib.sh` | shared helpers (sourced, not run) | — |

## Usage

```sh
# Run the whole suite
.meta/hooks/check-all.sh

# Enforce formatting too (used by CI on the pinned Crystal version)
APTORK_STRICT_FORMAT=1 .meta/hooks/check-all.sh

# Run an individual check
.meta/hooks/check-spec.sh
```

## Use as a git pre-push hook

```sh
ln -s ../../.meta/hooks/check-all.sh .git/hooks/pre-push
```

## Note on Crystal versions and formatting

`shard.yml` pins `crystal >= 1.12.0`. The formatter's output changed across
releases (e.g. trailing commas in multi-line argument lists are kept by Crystal
`>= 1.12` but stripped by older compilers). To avoid spurious formatting
failures for contributors on an older toolchain, `check-format.sh` only *warns*
on a difference unless `APTORK_STRICT_FORMAT=1` is set. CI sets it, so format is
still enforced on the supported compiler. Build and spec checks are always hard
failures regardless of compiler version.
