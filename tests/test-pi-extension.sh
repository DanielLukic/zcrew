#!/usr/bin/env bash
# Wrapper around tests/test-pi-extension.ts so the suite can be invoked
# the same way as the other test files. Uses node's experimental TS
# stripping so no bun / tsx dep is required.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec node --experimental-strip-types --no-warnings "$ROOT_DIR/tests/test-pi-extension.ts"
