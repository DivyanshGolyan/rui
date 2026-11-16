#!/usr/bin/env bash
set -euo pipefail
dir=$1
tarball="$dir/actionlint_1.7.7_linux_amd64.tar.gz"
verified() {
  echo "023070a287cd8cccd71515fedc843f1985bf96c436b7effaecce67290e7e0757  $tarball" | sha256sum --status -c -
}
if [ ! -f "$tarball" ] || ! verified; then
  rm -f "$tarball"
  # Through the API: anonymous release downloads fail under GitHub's load shedding.
  # The official release avoids rebuilding the Go CLI on every plan.
  gh release download v1.7.7 --repo rhysd/actionlint --pattern actionlint_1.7.7_linux_amd64.tar.gz --dir "$dir"
  verified || { echo "actionlint release digest mismatch" >&2; exit 1; }
fi
tar -xzf "$tarball" -C "$dir" actionlint
