#!/bin/sh
set -eu
cd "$(dirname "$0")"
exec python3 experiment.py --output raw.json "$@"
