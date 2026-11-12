wait_for_pattern() {
  local pattern="$1"
  local path="$2"
  local interval="$3"
  local attempts="$4"
  local label="$5"
  local attempt=0
  while (( attempt < attempts )); do
    if rg -q "$pattern" "$path" 2>/dev/null; then return 0; fi
    sleep "$interval"
    attempt=$((attempt + 1))
  done
  print -u2 "timed out waiting for $label"
  return 1
}
