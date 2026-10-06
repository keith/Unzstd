#!/usr/bin/env bash

set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

bazel build -c opt //:Unzstd
archive_path="$(bazel cquery -c opt --output=files //:Unzstd)"
install -m 644 "${archive_path}" Unzstd.zip

cat - << EOF
\`\`\`
$(sha256sum Unzstd.zip)
\`\`\`
EOF

open -R Unzstd.zip
