#!/usr/bin/env bash

set -euo pipefail

proj_dir="$(cd "$(dirname "$0")" && pwd)"
app_name="Unzstd"
app_path="/Applications/${app_name}.app"
backup_path="/tmp/${app_name}.app.bak"

cd "${proj_dir}"

echo "Building ${app_name}..."
bazel build -c opt //:Unzstd
archive_path="$(bazel cquery -c opt --output=files //:Unzstd)"
if [ ! -f "${archive_path}" ]; then
  echo "error: build archive not found at ${archive_path}" >&2
  exit 1
fi

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/${app_name}-deploy.XXXXXX")"
trap 'rm -rf "${staging_dir}"' EXIT
ditto -x -k "${archive_path}" "${staging_dir}"
built_app="${staging_dir}/${app_name}.app"
if [ ! -x "${built_app}/Contents/MacOS/${app_name}" ]; then
  echo "error: app executable not found in ${built_app}" >&2
  exit 1
fi

echo "Killing running ${app_name}..."
killall "${app_name}" 2>/dev/null || true

if [ -d "${app_path}" ]; then
  echo "Backing up ${app_path} to ${backup_path}..."
  rm -rf "${backup_path}"
  mv "${app_path}" "${backup_path}"
fi

echo "Installing new build to ${app_path}..."
mv "${built_app}" "${app_path}"

echo "Launching ${app_name} to register its file handlers..."
open "${app_path}"

echo "Done."
