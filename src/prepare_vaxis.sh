#!/usr/bin/env bash
set -euo pipefail

# Never mutate Zig's shared package cache. This build-owned source tree carries
# only the checked safety corrections against the manifest's exact upstream pin.
source=$1
patch_file=$2
destination=$3
mkdir -p "$destination"
cp -R "$source/." "$destination/"
patch --batch --forward -d "$destination" -p1 < "$patch_file"
