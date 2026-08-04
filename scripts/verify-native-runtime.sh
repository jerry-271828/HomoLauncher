#!/usr/bin/env sh
set -eu

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <launcher.har> [jre.hsp ...]" >&2
  exit 2
fi

launcher_har=$1
shift

for command_name in tar unzip readelf sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "missing command: $command_name" >&2
    exit 2
  fi
done

if [ ! -f "$launcher_har" ]; then
  echo "launcher HAR not found: $launcher_har" >&2
  exit 2
fi

audit_dir=$(mktemp -d "${TMPDIR:-/tmp}/homl-native-audit.XXXXXX")
trap 'rm -rf "$audit_dir"' EXIT

tar -xzf "$launcher_har" -C "$audit_dir" package/libs/arm64-v8a
source_dir="$audit_dir/package/libs/arm64-v8a"

has_code_signature() {
  readelf -SW "$1" | grep -F ' .codesign ' >/dev/null
}

source_count=0
for source_lib in "$source_dir"/*.so; do
  source_count=$((source_count + 1))
  if ! has_code_signature "$source_lib"; then
    echo "unsigned native library in $launcher_har: $(basename "$source_lib")" >&2
    exit 1
  fi
done

if [ "$source_count" -eq 0 ]; then
  echo "no native libraries found in $launcher_har" >&2
  exit 1
fi

echo "verified $source_count signed native libraries in $launcher_har"

hsp_index=0
for hsp_file in "$@"; do
  if [ ! -f "$hsp_file" ]; then
    echo "HSP not found: $hsp_file" >&2
    exit 2
  fi

  hsp_index=$((hsp_index + 1))
  hsp_dir="$audit_dir/hsp-$hsp_index"
  mkdir -p "$hsp_dir"
  unzip -q "$hsp_file" 'libs/arm64-v8a/*.so' -d "$hsp_dir"

  for source_lib in "$source_dir"/*.so; do
    lib_name=$(basename "$source_lib")
    packaged_lib="$hsp_dir/libs/arm64-v8a/$lib_name"
    if [ ! -f "$packaged_lib" ]; then
      echo "$hsp_file is missing launcher native library: $lib_name" >&2
      exit 1
    fi

    source_hash=$(sha256sum "$source_lib" | awk '{print $1}')
    packaged_hash=$(sha256sum "$packaged_lib" | awk '{print $1}')
    if [ "$source_hash" != "$packaged_hash" ]; then
      echo "$hsp_file contains stale native library: $lib_name" >&2
      echo "source=$source_hash packaged=$packaged_hash" >&2
      exit 1
    fi

    if ! has_code_signature "$packaged_lib"; then
      echo "$hsp_file contains unsigned native library: $lib_name" >&2
      exit 1
    fi
  done

  echo "verified native runtime payload in $hsp_file"
done
