#!/bin/sh
set -eu

directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
release_safe=$1
debug=$2

sh "$directory/admission_integration.sh" "$release_safe"
python3 "$directory/dispatch_integration.py" "$release_safe"
python3 "$directory/bash_owner_integration.py" "$release_safe"
python3 "$directory/bash_integration.py" "$release_safe"
python3 "$directory/bash_lifecycle_integration.py" "$release_safe"
python3 "$directory/bash_recovery_integration.py" "$release_safe"
python3 "$directory/control_integration.py" "$release_safe"
python3 "$directory/descriptor_capacity_integration.py" "$release_safe"
sh "$directory/admission_integration.sh" "$debug"
python3 "$directory/host_process_test.py"
