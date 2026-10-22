#!/bin/sh
# Fresh mapped Linux checks on dc246d7c, serial, one target per zig invocation. Runs at most once:
# the orb service restarts on exit, so a second start only idles.
export PATH=/home/user/rui-python/bin:$PATH
o=/home/user/workspace/repo/.amp/sqlv2/raw/fresh-run-5-dc246d7c
if [ -e $o/started ]; then exec sleep infinity; fi
touch $o/started
cd /tmp/v2land
echo "commit=$(git rev-parse HEAD) tree=$(git rev-parse HEAD^{tree}) parent=$(git rev-parse HEAD^)" > $o/identity.txt
for t in check admission-debug-integration dispatch-debug-integration codex-credential-integration codex-h2-integration current-facts-integration server-delivery-integration transport-h2-integration test-logic measurement-check bash-recovery-integration host-launch-integration terminal-restoration-integration; do
  echo "$(date -u +%FT%TZ) $t start" >> $o/final.log
  zig build $t > $o/$t.log 2>&1
  echo "$(date -u +%FT%TZ) $t EXIT=$?" >> $o/final.log
done
touch $o/done
exec sleep infinity
