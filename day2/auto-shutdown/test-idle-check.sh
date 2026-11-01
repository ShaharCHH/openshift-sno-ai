#!/usr/bin/env bash
# Offline test of idle-check.sh's decision helpers using canned input. No cluster
# or AWS access needed. Run: day2/auto-shutdown/test-idle-check.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export IDLE_CHECK_SOURCE_ONLY=1
# shellcheck source=idle-check.sh
source "$script_dir/idle-check.sh"

fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi
}

metrics='# HELP vllm:num_requests_running Number of requests in model execution batches.
vllm:num_requests_running{model_name="tinyllama"} 2.0
vllm:request_success_total{finished_reason="stop",model_name="tinyllama"} 40.0
vllm:request_success_total{finished_reason="length",model_name="tinyllama"} 2.0
vllm:num_requests_waiting{model_name="tinyllama"} 0.0'
check "llm metrics parsed" "2 42" "$(echo "$metrics" | llm_stats_from_metrics)"
check "llm metrics empty" "0 0" "$(echo "" | llm_stats_from_metrics)"

objs='{"items":[
 {"metadata":{"managedFields":[
   {"manager":"kube-controller-manager","time":"2026-10-29T10:00:00Z"},
   {"manager":"kubelet","time":"2026-10-29T11:00:00Z"}]}},
 {"metadata":{"managedFields":[
   {"manager":"kubectl-client-side-apply","time":"2026-10-29T08:00:00Z"},
   {"manager":"rhods-operator","time":"2026-10-29T12:00:00Z"}]}},
 {"metadata":{"managedFields":[
   {"manager":"Mozilla","time":"2026-10-29T09:00:00Z"}]}}]}'
# newest HUMAN entry is the Mozilla (console) one at 09:00; operators/kubelet at 10-12 are ignored
check "human change picks newest human, ignores operators" \
  "$(date -u -j -f %Y-%m-%dT%H:%M:%SZ 2026-10-29T09:00:00Z +%s 2>/dev/null || date -u -d 2026-10-29T09:00:00Z +%s)" \
  "$(echo "$objs" | latest_human_change_epoch)"
check "no human changes -> 0" "0" \
  "$(echo '{"items":[{"metadata":{"managedFields":[{"manager":"kubelet","time":"2026-10-29T11:00:00Z"}]}}]}' | latest_human_change_epoch)"
check "empty list -> 0" "0" "$(echo '{"items":[]}' | latest_human_change_epoch)"

check "newest login" "$(date -u -j -f %Y-%m-%dT%H:%M:%SZ 2026-10-29T10:30:00Z +%s 2>/dev/null || date -u -d 2026-10-29T10:30:00Z +%s)" \
  "$(echo '{"items":[{"metadata":{"creationTimestamp":"2026-10-28T10:00:00Z"}},{"metadata":{"creationTimestamp":"2026-10-29T10:30:00Z"}}]}' | latest_login_epoch)"

check "idle minutes" "125" "$(idle_minutes 10000 2500)"
check "max_of" "9" "$(max_of 3 9 0 7)"

exit "$fail"
