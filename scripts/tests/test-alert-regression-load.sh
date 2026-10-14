#!/usr/bin/env bash

set -Eeuo pipefail

TEST_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)" # 테스트 파일에서 저장소 루트를 찾는다.
source "${TEST_REPO_ROOT}/scripts/run-alert-regression.sh" # 실제 함수를 불러오며 외부 서비스 점검과 k6 실행은 시작하지 않는다.

TEST_LOG="$(mktemp)" # 계산 함수의 출력을 임시 파일에 저장한다.
trap 'rm -f -- "${TEST_LOG}"' EXIT # 테스트 종료 시 자신이 만든 로그만 삭제한다.
TEST_FAILURES=0

# 외부 Prometheus 조회만 대신하며 VU 계산과 안전 상한 검사는 실제 함수를 실행한다.
prometheus_query_value() {
  local expression="$1" # 실제 함수가 만든 PromQL을 받아 시간 창과 요청 종류에 맞는 값을 반환한다.
  local total
  local bad

  case "${expression}" in
    *'[1h]'*) total="${TEST_TOTAL_1H}"; bad="${TEST_BAD_1H}" ;;
    *'[5m]'*)
      if [[ "${TEST_FAIL_5M:-no}" == "yes" ]]; then
        return 1 # 5분 이력을 조회할 수 없는 상황을 재현한다.
      fi
      total="${TEST_TOTAL_5M}"; bad="${TEST_BAD_5M}"
      ;;
    *) echo "Unexpected history window: ${expression}" >&2; return 1 ;;
  esac

  case "${expression}" in
    clamp_min*|*'status_code=~"5.."'*) echo "${bad}" ;;
    *) echo "${total}" ;;
  esac
}

assert_load() {
  local description="$1"
  local scenario="$2"
  TEST_TOTAL_1H="$3"
  TEST_BAD_1H="$4"
  TEST_TOTAL_5M="$5"
  TEST_BAD_5M="$6"
  local expected="$7" # 손으로 계산한 VU 수 또는 reject를 기대 결과로 사용한다.
  local status=0
  local actual

  configure_scenario "${scenario}"
  prepare_scenario_load > "${TEST_LOG}" 2>&1 || status=$? # 실패 종료도 결과로 검사한다.

  if [[ "${scenario}" == "latency" ]]; then
    actual="${K6_LATENCY_VUS}"
  else
    actual="${K6_ERROR_RATE_VUS}"
  fi

  if [[ "${expected}" == "reject" ]]; then
    if (( status != 0 )) && [[ -z "${actual}" ]]; then
      echo "[PASS] ${description}"
      return
    fi
  elif (( status == 0 )) && [[ "${actual}" == "${expected}" ]]; then
    echo "[PASS] ${description}"
    return
  fi

  echo "[FAIL] ${description}: expected=${expected}, actual=${actual:-unset}, status=${status}" >&2
  cat "${TEST_LOG}" >&2
  TEST_FAILURES=$(( TEST_FAILURES + 1 ))
}

# 과거 장애 요청이 1시간 계산을 만족시켜도 최근 5분 정상 요청을 무시하면 실패해야 한다.
assert_load "latency: recent normal traffic controls VUs" latency 3100 3000 100 0 10
assert_load "latency: recent baseline exceeds safe cap" latency 3450 3000 450 0 reject
assert_load "error-rate: recent normal traffic controls VUs" error-rate 5000 3000 2000 0 6
assert_load "error-rate: recent normal traffic exceeds safe cap" error-rate 13000 3000 10000 0 reject

# 과거 장애 요청이 만료되어도 정상 요청 대비 필요한 새 부하와 안전 상한을 유지한다.
assert_load "latency: expiring slow requests do not reduce new load" latency 400 280 400 280 12
assert_load "latency: expiring slow requests cannot hide unsafe load" latency 1200 840 1200 840 reject
assert_load "error-rate: expiring 5xx requests do not reduce new load" error-rate 1000 140 1000 140 3
assert_load "error-rate: expiring 5xx requests cannot hide unsafe load" error-rate 11200 1568 11200 1568 reject

# 기존 1시간 이력 보정과 최소 부하 동작도 유지되어야 한다.
assert_load "latency: one-hour history controls VUs" latency 100 0 0 0 10
assert_load "latency: one-hour history exceeds safe cap" latency 450 0 0 0 reject
assert_load "error-rate: one-hour history controls VUs" error-rate 1784 0 0 0 5
assert_load "error-rate: one-hour history exceeds safe cap" error-rate 10000 0 0 0 reject
assert_load "latency: empty history uses minimum VUs" latency 0 0 0 0 3
assert_load "error-rate: empty history uses minimum VUs" error-rate 0 0 0 0 2

TEST_FAIL_5M=yes
assert_load "latency: unavailable 5m history rejects load" latency 0 0 0 0 reject
assert_load "error-rate: unavailable 5m history rejects load" error-rate 0 0 0 0 reject

if (( TEST_FAILURES > 0 )); then
  echo "${TEST_FAILURES} load-sizing tests failed." >&2
  exit 1
fi

echo "All load-sizing tests passed."
