#!/usr/bin/env bash
# Run Nomad jobs for real on a throw-away `nomad agent -dev` (CI: a GitHub runner with Docker):
#   - validate every job file (also the ones that need Vault/Consul and so cannot run here),
#   - l1: run the nginx job, wait until both allocations are healthy, curl them,
#   - l-max: register the parameterized job, dispatch it with metadata + payload, check the child's output.
# Usage: sudo -E bash ci/nomad-dev-agent-smoke.sh      (needs nomad and docker; starts and stops its own agent)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NOMAD_ADDR="http://127.0.0.1:4646"
AGENT_LOG="$(mktemp)"

nomad agent -dev -bind=127.0.0.1 >"${AGENT_LOG}" 2>&1 &
AGENT_PID=$!
cleanup() {
  local rc=$?
  if [[ ${rc} -ne 0 ]]; then
    echo "::group::nomad agent log"; tail -n 80 "${AGENT_LOG}"; echo "::endgroup::"
    nomad job status 2>/dev/null || true
  fi
  kill "${AGENT_PID}" 2>/dev/null || true
  exit "${rc}"
}
trap cleanup EXIT

echo "== waiting for the dev agent"
for _ in $(seq 1 60); do
  if nomad node status 2>/dev/null | grep -q ready; then break; fi
  sleep 2
done
nomad node status | grep -q ready

echo "== validate all jobs"
for f in "${ROOT}"/nomad/*/*.nomad.hcl; do
  echo "-- ${f#"${ROOT}"/}"
  nomad job validate "${f}"
done

echo "== l1: run the nginx job"
nomad job run "${ROOT}/nomad/l1-job-spec-basic/nginx-web-server-docker-driver.nomad.hcl"
nomad job status nginx-web
# `job run` blocks until the deployment is healthy; both allocations must answer on their own host port.
ADDRS="$(nomad service info -json nginx-web | python3 -c '
import json, sys
for s in json.load(sys.stdin):
    print("%s:%s" % (s["Address"], s["Port"]))')"
test "$(echo "${ADDRS}" | wc -l)" -eq 2
for addr in ${ADDRS}; do
  echo "GET http://${addr}/health"
  test "$(curl -fsS "http://${addr}/health")" = OK
  curl -fsS "http://${addr}/" | grep -q "Welcome to nginx"
done
nomad job stop -purge nginx-web

echo "== l-max: parameterized dispatch"
nomad job run "${ROOT}/nomad/l-max-parameterized-dispatch/batch-job-parameterized-dispatch.nomad.hcl"
PAYLOAD="$(mktemp)"
echo '{"rows":[1,2,3]}' > "${PAYLOAD}"

# A missing required meta key must be refused.
if nomad job dispatch batch-report-generator "${PAYLOAD}" >/dev/null 2>&1; then
  echo "dispatch without REPORT_TYPE should fail"; exit 1
fi

OUT="$(nomad job dispatch -detach -meta REPORT_TYPE=daily -meta OUTPUT_FORMAT=csv batch-report-generator "${PAYLOAD}")"
echo "${OUT}"
CHILD="$(echo "${OUT}" | awk '/Dispatched Job ID/ {print $NF}')"
test -n "${CHILD}"

for _ in $(seq 1 60); do
  STATUS="$(nomad job status -short "${CHILD}" | awk '/^Status/ {print $NF}')"
  [[ "${STATUS}" == dead ]] && break
  sleep 2
done
test "${STATUS}" = dead
nomad job status "${CHILD}"

LOGS="$(nomad alloc logs -job "${CHILD}" report-task)"
echo "${LOGS}"
echo "${LOGS}" | grep -q "type=daily format=csv"
echo "${LOGS}" | grep -q "notify=ops@example.com"     # default meta applied
echo "${LOGS}" | grep -q "wrote /alloc/data/report.csv"
echo "${LOGS}" | grep -qF 'json-schema.org'                   # the downloaded artifact was readable

# Omitting the optional key falls back to the job-level default instead of an empty string.
OUT2="$(nomad job dispatch -detach -meta REPORT_TYPE=weekly batch-report-generator "${PAYLOAD}")"
CHILD2="$(echo "${OUT2}" | awk '/Dispatched Job ID/ {print $NF}')"
for _ in $(seq 1 60); do
  STATUS="$(nomad job status -short "${CHILD2}" | awk '/^Status/ {print $NF}')"
  [[ "${STATUS}" == dead ]] && break
  sleep 2
done
nomad alloc logs -job "${CHILD2}" report-task | grep -q "type=weekly format=json"

echo "Nomad l1 and l-max verified on a dev agent."
