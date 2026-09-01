#!/bin/sh
set -eu

onepage_binary=$1
memory_contract_binary=$2
memory_report_path=$3
# A failed rerun must not leave an older successful observation at the
# canonical evidence path.
rm -f "$memory_report_path"
live_root=$(mktemp -d "${TMPDIR:-/tmp}/onepage-codex-live.XXXXXX")
report_temp=
onepage_pid=
footprint_pid=
capture_metrics_path="$live_root/codex-capture-metrics.json"

terminate_child() {
  child_pid=$1
  if test -z "$child_pid"; then
    return
  fi
  # The child may exit between sampling and termination. A non-zero wait is
  # also expected after SIGTERM; either result is safe once the child is gone.
  kill "$child_pid" 2>/dev/null || true
  wait "$child_pid" 2>/dev/null || true
}

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  terminate_child "$footprint_pid"
  terminate_child "$onepage_pid"
  if test -n "$report_temp"; then
    rm -f "$report_temp"
  fi
  if test "$status" -eq 0; then
    rm -rf "$live_root"
  else
    printf 'Failed live fixture preserved at: %s\n' "$live_root" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
repo_dir="$live_root/repo"
mkdir "$repo_dir"

git -C "$repo_dir" init -q
git -C "$repo_dir" config user.email onepage-live@example.invalid
git -C "$repo_dir" config user.name "OnePage live fixture"
printf '%s\n' broken > "$repo_dir/status.txt"
printf '%s\n' '#!/bin/sh' 'test "$(cat status.txt)" = fixed' > "$repo_dir/test.sh"
chmod +x "$repo_dir/test.sh"
git -C "$repo_dir" add status.txt test.sh
git -C "$repo_dir" commit -qm fixture

peak_rss_bytes=0
peak_virtual_bytes=0
peak_thread_count=0
peak_tcp_connection_count=0
peak_tcp_receive_queue_bytes=0
peak_tcp_send_queue_bytes=0
peak_tcp_receive_high_water_bytes=0
peak_tcp_send_high_water_bytes=0
no_active_tcp_peak_rss_bytes=0
active_transport_peak_rss_bytes=0
last_no_socket_rss_bytes=0
transport_baseline_rss_bytes=0
whole_process_stack_virtual_bytes_during_active_tcp=0
stack_sampled=false

maximum() {
  if test "$2" -gt "$1"; then
    printf '%s\n' "$2"
  else
    printf '%s\n' "$1"
  fi
}

sample_process() {
  process_values=$(/bin/ps -o rss=,vsz= -p "$onepage_pid" 2>/dev/null || true)
  if test -z "$process_values"; then
    return
  fi
  set -- $process_values
  rss_bytes=$(($1 * 1024))
  virtual_bytes=$(($2 * 1024))
  thread_count=$(/bin/ps -M -p "$onepage_pid" 2>/dev/null | awk 'NR > 1 { count += 1 } END { print count + 0 }')
  socket_values=$(/usr/sbin/netstat -anv -p tcp 2>/dev/null | awk -v process="$onepage_pid" '
    NR > 2 && $11 == process {
      count += 1
      receive_queue += $2
      send_queue += $3
      receive_high_water += $9
      send_high_water += $10
    }
    END { print count + 0, receive_queue + 0, send_queue + 0, receive_high_water + 0, send_high_water + 0 }
  ')
  set -- $socket_values
  tcp_connection_count=$1
  tcp_receive_queue_bytes=$2
  tcp_send_queue_bytes=$3
  tcp_receive_high_water_bytes=$4
  tcp_send_high_water_bytes=$5

  peak_rss_bytes=$(maximum "$peak_rss_bytes" "$rss_bytes")
  peak_virtual_bytes=$(maximum "$peak_virtual_bytes" "$virtual_bytes")
  peak_thread_count=$(maximum "$peak_thread_count" "$thread_count")
  peak_tcp_connection_count=$(maximum "$peak_tcp_connection_count" "$tcp_connection_count")
  peak_tcp_receive_queue_bytes=$(maximum "$peak_tcp_receive_queue_bytes" "$tcp_receive_queue_bytes")
  peak_tcp_send_queue_bytes=$(maximum "$peak_tcp_send_queue_bytes" "$tcp_send_queue_bytes")
  peak_tcp_receive_high_water_bytes=$(maximum "$peak_tcp_receive_high_water_bytes" "$tcp_receive_high_water_bytes")
  peak_tcp_send_high_water_bytes=$(maximum "$peak_tcp_send_high_water_bytes" "$tcp_send_high_water_bytes")

  if test "$tcp_connection_count" -eq 0; then
    no_active_tcp_peak_rss_bytes=$(maximum "$no_active_tcp_peak_rss_bytes" "$rss_bytes")
    last_no_socket_rss_bytes=$rss_bytes
  else
    active_transport_peak_rss_bytes=$(maximum "$active_transport_peak_rss_bytes" "$rss_bytes")
    if test "$transport_baseline_rss_bytes" -eq 0; then
      transport_baseline_rss_bytes=$last_no_socket_rss_bytes
    fi
    if test "$stack_sampled" = false; then
      page_size=$(getconf PAGESIZE)
      stack_pages=$(/usr/bin/vmmap -summary -pages "$onepage_pid" 2>/dev/null | awk '$1 == "Stack" { print $2; exit }')
      if test -n "$stack_pages"; then
        whole_process_stack_virtual_bytes_during_active_tcp=$((stack_pages * page_size))
      fi
      stack_sampled=true
    fi
  fi
}

set +e
"$onepage_binary" \
  --state "$live_root/state" \
  --repo "$repo_dir" \
  --model codex:gpt-5.6-sol \
  --codex-capture-metrics "$capture_metrics_path" \
  --dangerously-bypass-permissions \
  "Run ./test.sh, diagnose the failure, change only status.txt so the test passes, run ./test.sh again, and finish with a concise summary." \
  > "$live_root/output.txt" 2>&1 &
onepage_pid=$!

footprint_output="$live_root/footprint.txt"
/usr/bin/footprint \
  -p "$onepage_pid" \
  -f bytes \
  --noCategories \
  --sample 0.2 \
  --sample-duration 900 \
  > "$footprint_output" 2>&1 &
footprint_pid=$!

while process_state=$(/bin/ps -o stat= -p "$onepage_pid" 2>/dev/null); do
  case "$process_state" in
    *Z*) break ;;
  esac
  sample_process
  sleep 0.2
done

wait "$onepage_pid"
onepage_status=$?
onepage_pid=
terminate_child "$footprint_pid"
footprint_pid=
set -e

cat "$live_root/output.txt"
if test "$onepage_status" -ne 0; then
  exit "$onepage_status"
fi
grep -q '^Final Answer:$' "$live_root/output.txt"
test "$(cat "$repo_dir/status.txt")" = fixed
(cd "$repo_dir" && ./test.sh)
test "$(git -C "$repo_dir" diff --name-only)" = status.txt

peak_phys_footprint_bytes=$(awk '
  /phys_footprint_peak:/ && $2 > peak { peak = $2 }
  END { print peak + 0 }
' "$footprint_output")
transport_baseline_report=null
observed_transport_rss_increase_bytes=null
if test "$transport_baseline_rss_bytes" -gt 0; then
  transport_baseline_report=$transport_baseline_rss_bytes
  observed_transport_rss_increase_bytes=0
  if test "$active_transport_peak_rss_bytes" -gt "$transport_baseline_rss_bytes"; then
    observed_transport_rss_increase_bytes=$((active_transport_peak_rss_bytes - transport_baseline_rss_bytes))
  fi
fi

adapter_contract=$("$memory_contract_binary")
if ! test -s "$capture_metrics_path"; then
  printf 'Successful live run produced no Codex capture metrics.\n' >&2
  exit 1
fi
capture_metrics=$(cat "$capture_metrics_path")
for required_measurement in \
  "$peak_rss_bytes" \
  "$peak_phys_footprint_bytes" \
  "$active_transport_peak_rss_bytes" \
  "$peak_thread_count" \
  "$whole_process_stack_virtual_bytes_during_active_tcp" \
  "$peak_tcp_connection_count"
do
  if test "$required_measurement" -eq 0; then
    printf 'Successful live run produced an incomplete memory report.\n' >&2
    exit 1
  fi
done
report_directory=$(dirname "$memory_report_path")
mkdir -p "$report_directory"
report_temp="${memory_report_path}.tmp.$$"
measured_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
os_version=$(sw_vers -productVersion)
machine_model=$(sysctl -n hw.model)
architecture=$(uname -m)
script_directory=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
source_commit=$(git -C "$script_directory/.." rev-parse HEAD)
{
    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "scope": "capacity_one_live_codex_turn",\n'
    printf '  "measured_at": "%s",\n' "$measured_at"
    printf '  "source_commit": "%s",\n' "$source_commit"
    printf '  "platform": {"os": "macOS", "version": "%s", "architecture": "%s", "model": "%s"},\n' "$os_version" "$architecture" "$machine_model"
    printf '  "adapter_contract": %s,\n' "$adapter_contract"
    printf '  "capture_observation": %s,\n' "$capture_metrics"
    printf '  "process": {\n'
    printf '    "measurement_scope": "whole_onepage_process_not_transport_delta",\n'
    printf '    "sampling_interval_milliseconds": 200,\n'
    printf '    "peak_rss_bytes": %s,\n' "$peak_rss_bytes"
    printf '    "peak_physical_footprint_bytes": %s,\n' "$peak_phys_footprint_bytes"
    printf '    "peak_virtual_bytes": %s,\n' "$peak_virtual_bytes"
    printf '    "no_active_tcp_peak_rss_bytes": %s,\n' "$no_active_tcp_peak_rss_bytes"
    printf '    "transport_baseline_rss_bytes": %s,\n' "$transport_baseline_report"
    printf '    "active_transport_peak_rss_bytes": %s,\n' "$active_transport_peak_rss_bytes"
    printf '    "observed_transport_rss_increase_upper_bound_bytes": %s,\n' "$observed_transport_rss_increase_bytes"
    printf '    "peak_thread_count": %s,\n' "$peak_thread_count"
    printf '    "whole_process_stack_virtual_bytes_during_active_tcp": %s\n' "$whole_process_stack_virtual_bytes_during_active_tcp"
    printf '  },\n'
    printf '  "tcp": {\n'
    printf '    "measurement": "macOS netstat queues and configured high-water limits, not allocated kernel memory",\n'
    printf '    "peak_connection_count": %s,\n' "$peak_tcp_connection_count"
    printf '    "peak_receive_queue_bytes": %s,\n' "$peak_tcp_receive_queue_bytes"
    printf '    "peak_send_queue_bytes": %s,\n' "$peak_tcp_send_queue_bytes"
    printf '    "peak_receive_high_water_bytes": %s,\n' "$peak_tcp_receive_high_water_bytes"
    printf '    "peak_send_high_water_bytes": %s,\n' "$peak_tcp_send_high_water_bytes"
    printf '    "http_keep_alive": false,\n'
    printf '    "idle_pool_capacity": 0\n'
    printf '  }\n'
    printf '}\n'
} > "$report_temp"
mv "$report_temp" "$memory_report_path"
report_temp=
printf 'Capacity-one memory report: %s\n' "$memory_report_path"
