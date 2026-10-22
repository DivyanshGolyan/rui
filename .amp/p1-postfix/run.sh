#!/usr/bin/env bash
set -eu
ROOT=/home/user/workspace/repo
SOURCE=$ROOT/.amp/p1-postfix-source
OUT=$ROOT/.amp/p1-postfix/raw
BINARY=$SOURCE/.amp/p1/build/bin/rui
HARNESS=$ROOT/.amp/p1/bin/model-output
REV=d4f870002b1eeef370fb8f4c7aa3fd8b14343159
cd "$ROOT"
# Supervised services restart finite commands. Claim before any truncation or launch.
if ! mkdir "$OUT/launch-once" 2>/dev/null; then
    exec sleep infinity
fi
exec >> "$OUT/campaign.log" 2>&1
printf 'campaign_start_utc=%s\nsource=%s\n' "$(date -u +%FT%TZ)" "$REV"
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$REV"
test -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)"
test "$(sha256sum "$HARNESS" | cut -d' ' -f1)" = 7f4fe110b5efbab175a51006d5a563cd2624ab6d0b86c35554ccbe9a2e05ade6
{
    printf 'build_start_utc=%s\nsource=%s\n' "$(date -u +%FT%TZ)" "$REV"
    printf 'command=ZIG_LOCAL_PKG_DIR=%s/zig-pkg ZIG_LOCAL_CACHE_DIR=%s/.zig-cache zig build -Doptimize=ReleaseFast --prefix .amp/p1/build -j2 --summary all\n' "$ROOT" "$ROOT"
    (
        cd "$SOURCE"
        env ZIG_LOCAL_PKG_DIR="$ROOT/zig-pkg" ZIG_LOCAL_CACHE_DIR="$ROOT/.zig-cache" \
            zig build -Doptimize=ReleaseFast --prefix .amp/p1/build -j2 --summary all
    )
    printf 'build_exit=0\nbuild_end_utc=%s\n' "$(date -u +%FT%TZ)"
    sha256sum "$BINARY"
} > "$OUT/build-releasefast.log" 2>&1
{
    date -u +identity_utc=%FT%TZ
    printf 'source=%s\nharness_source=a204296c7289cf0a90f95df155c4f27832c924fe\n' "$REV"
    uname -srvmo
    getconf _NPROCESSORS_ONLN
    getconf CLK_TCK
    ulimit -Sn
    lscpu | grep -E '^(Model name|CPU\(s\)|Thread\(s\) per core|Core\(s\) per socket|Hypervisor vendor):'
    cat /sys/fs/cgroup/amp.slice/amp-workload.slice/cpu.max
    cat /sys/fs/cgroup/amp.slice/amp-workload.slice/memory.max
    zig version
    go version
    sha256sum "$BINARY" "$HARNESS"
    printf 'execution=managed orb service; no profiler/test/build overlaps capture windows\n'
} > "$OUT/identity.txt"
git -C "$SOURCE" ls-files src build.zig build.zig.zon | while IFS= read -r path; do
    sha256sum "$SOURCE/$path"
done > "$OUT/product-source.sha256"
sha256sum tests/qualification/model-output/main.go tests/qualification/model-output/provider/main.go \
    tests/qualification/go.mod tests/qualification/go.sum > "$OUT/harness-source.sha256"

run_case() {
    name=$1
    estimate=$2
    shift 2
    printf 'case_start=%s %s\n' "$name" "$(date -u +%FT%TZ)"
    {
        printf 'start_utc=%s\ncase=%s\nsource=%s\nexpectation=%s\n' "$(date -u +%FT%TZ)" "$name" "$REV" "$estimate"
        sha256sum "$BINARY" "$HARNESS"
        printf 'environment=unset LD_PRELOAD GLIBC_TUNABLES RUI_MEASURE_GLIBC_TUNABLES\n'
    } > "$OUT/$name.log"
    set +e
    env -u LD_PRELOAD -u GLIBC_TUNABLES -u RUI_MEASURE_GLIBC_TUNABLES \
        "$HARNESS" --sessions 100 "$@" --expectation "$estimate" --output "$OUT/$name.json" "$BINARY" \
        >> "$OUT/$name.log" 2>&1
    code=$?
    set -e
    printf 'exit=%s\nend_utc=%s\n' "$code" "$(date -u +%FT%TZ)" >> "$OUT/$name.log"
    printf 'case_end=%s exit=%s %s\n' "$name" "$code" "$(date -u +%FT%TZ)"
    test "$code" -eq 0
}

run_case run-stream100 '13.6 MB end-window Host PSS and 0 steady clients estimated from prior STREAM100 median; 0.45 average Host cores estimated; actual STREAM in-window events/rate unavailable'
run_case run-hold100 '13.45 MB end-window Host PSS, 40 voluntary thread switches/s and 1.54 Host CPU-seconds/60s estimated from prior intake-only HOLD median; distinct wakeups unavailable' --hold
printf 'campaign_end_utc=%s\n' "$(date -u +%FT%TZ)"
exec sleep infinity
