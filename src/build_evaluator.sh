#!/bin/sh
set -eu
# Leave the pinned dependency untouched. Apply the evaluator-only parser policy
# to the generated translation unit, then append the private reader and module
# check where the engine's internal string and module types are defined.
cat "$1" > "$2"
patch -F 0 -s "$2" "$3"
printf '\n#include "evaluator_string_reader.inc"\n#include "evaluator_policy.inc"\n' >> "$2"
