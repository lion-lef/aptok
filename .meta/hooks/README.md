# Aptok spec-check hooks

Shell hooks that **check the spec** — they verify the library still builds and
that every example in `spec/` passes. They are plain POSIX `sh` scripts so they
run identically on a developer machine, in a git hook, or in CI.

## Scripts

| Script | What it checks | Failure mode |
| --- | --- | --- |
| `check-format.sh` | `crystal tool format --check src spec` | warning by default, hard failure with `APTOK_STRICT_FORMAT=1` |
| `check-build.sh` | `crystal build src/aptok.cr --no-codegen` (type check) | hard failure |
| `check-spec.sh` | `crystal spec` (the full example suite) | hard failure |
| `check-all.sh` | runs all three in order | non-zero if any hard check fails |
| `lib.sh` | shared helpers (sourced, not run) | — |

## Usage

```sh
# Run the whole suite
.meta/hooks/check-all.sh

# Enforce formatting too (used by CI on the pinned Crystal version)
APTOK_STRICT_FORMAT=1 .meta/hooks/check-all.sh

# Run an individual check
.meta/hooks/check-spec.sh
```

## Use as a git pre-push hook

```sh
ln -s ../../.meta/hooks/check-all.sh .git/hooks/pre-push
```

## Note on Crystal versions and formatting

`shard.yml` pins `crystal >= 1.12.0`. The sources are formatted with
`crystal tool format` and verified clean on both Crystal 1.11.x and the pinned
1.12.2 (the version CI uses), so the check passes regardless of which of those
compilers a contributor runs. The formatter's output can nonetheless drift
between releases, so to avoid spurious failures on an unexpected toolchain
`check-format.sh` only *warns* on a difference unless `APTOK_STRICT_FORMAT=1`
is set. CI sets it, so format is still enforced on the supported compiler.
Build and spec checks are always hard failures regardless of compiler version.
