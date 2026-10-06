#!/usr/bin/env bash

set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

swift_files=()
while IFS= read -r -d '' file; do
  if [[ -f "$file" && ! -L "$file" ]]; then
    swift_files+=("./$file")
  fi
done < <(git ls-files -z --cached --others --exclude-standard -- '*.swift')

if [[ ${#swift_files[@]} -eq 0 ]]; then
  exit 0
fi

# swift-format's in-place mode does not report whether it changed a file.
before=$(shasum -a 256 "${swift_files[@]}")
xcrun swift-format format --in-place --parallel "${swift_files[@]}"
after=$(shasum -a 256 "${swift_files[@]}")

# Formatting skips lint-only rules.
xcrun swift-format lint --strict --parallel "${swift_files[@]}"

if [[ "$before" != "$after" ]]; then
  exit 1
fi
