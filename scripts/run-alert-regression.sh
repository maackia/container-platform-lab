#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" # 현재 스크립트가 위치한 디렉터리의 절대 경로를 구한다.
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)" # scripts 디렉터리의 상위 경로를 저장소 루트로 사용한다.

K6_BASE_URL="${K6_BASE_URL:-http://127.0.0.1}"
K6_TARGET_HOST="${K6_TARGET_HOST:-app.platform.local}"

PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1}"
PROMETHEUS_HOST="${PROMETHEUS_HOST:-prometheus.platform.local}" # Traefik이 Prometheus Ingress를 선택할 Host 헤더다.

ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://127.0.0.1}"
ALERTMANAGER_HOST="${ALERTMANAGER_HOST:-alertmanager.platform.local}" # Traefik이 Alertmanager Ingress를 선택할 Host 헤더다.

POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}" # 경고 상태를 10초마다 조회한다.
FIRING_TIMEOUT_SECONDS="${FIRING_TIMEOUT_SECONDS:-240}" # FIRING 상태를 최대 4분 동안 기다린다.
ALERTMANAGER_TIMEOUT_SECONDS="${ALERTMANAGER_TIMEOUT_SECONDS:-120}" # Alertmanager 전달과 해제를 최대 2분 동안 기다린다.
RESOLVED_TIMEOUT_SECONDS="${RESOLVED_TIMEOUT_SECONDS:-600}" # Prometheus RESOLVED를 최대 10분 동안 기다린다.

PROMETHEUS_RULES_JSON="" # Prometheus에서 받은 전체 규칙 JSON을 저장한다.

CURRENT_SCENARIO="" # 현재 실행 중인 시나리오 이름을 저장한다.
CURRENT_K6_PID="" # 백그라운드에서 실행 중인 k6 프로세스 ID를 저장한다.
CURRENT_K6_LOG="" # k6 출력을 저장할 임시 파일 경로다.
K6_SCRIPT="" # 현재 시나리오에서 실행할 k6 파일 경로를 저장한다.

REQUIRED_ALERTS=() # 반드시 FIRING과 RESOLVED를 확인할 경고를 저장한다.
REQUIRED_RECORDING_RULES=() # 반드시 Prometheus에 로드되어 있어야 할 Recording Rule을 저장한다.
OPTIONAL_ALERTS=() # 과거 데이터에 따라 발생할 수도 있는 경고를 저장한다.

# 모든 HTTP 점검에서 공통으로 사용할 curl 옵션이다.
CURL_OPTIONS=(
  --silent                 # 정상 응답의 진행률을 출력하지 않는다.
  --show-error             # curl 요청 실패 메시지는 출력한다.
  --fail                   # HTTP 400·500번대 응답을 실패로 처리한다.
  --noproxy "*"            # 로컬 실습 주소는 프록시를 거치지 않는다.
  --connect-timeout 3      # 서버 연결을 최대 3초 동안 기다린다.
  --max-time 10            # 전체 요청은 최대 10초까지만 허용한다.
)

# 실행 가능한 모드와 사용 방법을 출력한다.
usage() {
  echo "Usage: ./scripts/run-alert-regression.sh [latency|error-rate|all|check]"
  echo
  echo "Modes:"
  echo "  latency     Run the latency alert regression test. This is the default."
  echo "  error-rate  Run the error-rate alert regression test."
  echo "  all         Run latency and error-rate tests sequentially."
  echo "  check       Run only preflight, rule and inactive-state checks."
  echo
  echo "Discord FIRING and RESOLVED messages must be checked manually."
}

# 스크립트가 종료될 때 실행 중인 k6 프로세스를 종료하고 임시 로그 파일을 삭제한다.
cleanup() {
  if [[ -n "${CURRENT_K6_PID}" ]] && kill -0 "${CURRENT_K6_PID}" 2> /dev/null; then # k6 프로세스가 아직 실행 중인지 확인한다.
    echo
    echo "[INFO] Stopping k6 process (PID: ${CURRENT_K6_PID})..."
    kill "${CURRENT_K6_PID}" 2> /dev/null || true # k6를 종료하며 이미 종료된 경우에는 오류를 무시한다.
    wait "${CURRENT_K6_PID}" 2> /dev/null || true # 프로세스가 완전히 종료될 때까지 기다린다.
  fi

  if [[ -n "${CURRENT_K6_LOG}" && -f "${CURRENT_K6_LOG}" ]]; then # 임시 로그 파일이 존재하는지 확인한다.
    echo "[INFO] Removing temporary k6 log file: ${CURRENT_K6_LOG}"
    rm -f -- "${CURRENT_K6_LOG}" || true # 임시 로그 파일을 삭제한다.
  fi
}

trap cleanup EXIT # 정상 종료와 오류 종료 모두에서 cleanup 함수를 실행한다.

# 실행할 시나리오에 맞게 k6 파일과 검사 대상을 설정한다.
configure_scenario() {
  local scenario="$1" # 함수에 전달된 첫 번째 값을 시나리오 이름으로 저장한다.

  CURRENT_SCENARIO="${scenario}" # 현재 실행 중인 시나리오 이름을 전역 변수에 저장한다.

  case "${scenario}" in # 전달된 시나리오에 맞는 설정을 선택한다.
    latency)
      K6_SCRIPT="${REPO_ROOT}/load-tests/latency.js"

      REQUIRED_ALERTS=(
        "PlatformAppHighP95Latency"
        "PlatformAppHttpLatencyFastBurn"
      )

      REQUIRED_RECORDING_RULES=(
        "platform_app:slo_http_latency_burn_rate:5m"
        "platform_app:slo_http_latency_burn_rate:1h"
      )

      OPTIONAL_ALERTS=(
        "PlatformAppHttpLatencySustainedBurn"
      )
      ;;

    error-rate)
      K6_SCRIPT="${REPO_ROOT}/load-tests/error-rate.js"

      REQUIRED_ALERTS=(
        "PlatformAppHighErrorRate"
        "PlatformAppHttpSuccessFastBurn"
      )

      REQUIRED_RECORDING_RULES=(
        "platform_app:slo_http_success_burn_rate:5m"
        "platform_app:slo_http_success_burn_rate:1h"
      )

      OPTIONAL_ALERTS=(
        "PlatformAppHttpSuccessSustainedBurn"
      )
      ;;

    *)
      echo "[FAIL] Unsupported scenario: ${scenario}" >&2
      return 1
      ;;
  esac
}

# 필요한 명령어가 설치되어 있는지 확인한다.
require_command() {
  local command_name="$1" # 함수의 첫 번째 인자를 검사할 명령어 이름으로 저장한다.

  if command -v "${command_name}" > /dev/null 2>&1; then # 명령어가 PATH에서 발견되는지 확인한다.
    echo "[PASS] ${command_name} is installed."
  else
    echo "[FAIL] Required command not found: ${command_name}" >&2
    exit 1
  fi
}

# 애플리케이션의 /health 엔드포인트를 점검한다.
check_health() {
  if curl \
    "${CURL_OPTIONS[@]}" \
    --header "Host: ${K6_TARGET_HOST}" \
    "${K6_BASE_URL}/health" \
    > /dev/null; then

    echo "[PASS] Health check passed."
  else
    echo "[FAIL] Health check failed." >&2
    exit 1
  fi
}

# 연결 주소와 Traefik Host 헤더를 받아 모니터링 서비스의 준비 상태를 확인한다.
check_endpoint() {
  local endpoint_name="$1" # 화면에 표시할 서비스 이름을 저장한다.
  local endpoint_url="$2" # 실제로 요청할 URL을 저장한다.
  local endpoint_host="$3" # Traefik 라우팅에 사용할 Host 헤더를 저장한다.

  if curl \
    "${CURL_OPTIONS[@]}" \
    --header "Host: ${endpoint_host}" \
    "${endpoint_url}" \
    > /dev/null; then

    echo "[PASS] ${endpoint_name} is ready"
  else
    echo "[FAIL] ${endpoint_name} readiness check failed" >&2
    exit 1
  fi
}

# Ubuntu의 NTP 서비스와 시간 동기화 상태를 확인한다.
check_ntp() {
  local ntp_status # systemd-timesyncd 서비스 상태를 저장한다.
  local ntp_sync # 운영체제의 시간 동기화 여부를 저장한다.

  ntp_status="$(systemctl is-active systemd-timesyncd 2> /dev/null || true)" # systemctl 실패로 스크립트가 즉시 종료되지 않게 한다.
  ntp_sync="$(timedatectl show --property=NTPSynchronized --value)" # 동기화 여부를 yes 또는 no로 조회한다.

  if [[ "${ntp_status}" == "active" && "${ntp_sync}" == "yes" ]]; then
    echo "[PASS] System clock is synchronized with NTP."
  else
    echo "[FAIL] System clock is not synchronized." >&2
    echo "       NTP service: ${ntp_status}" >&2
    echo "       NTP synchronized: ${ntp_sync}" >&2
    echo "       Run: sudo systemctl restart systemd-timesyncd" >&2
    exit 1
  fi
}

# 전달받은 PromQL을 Prometheus HTTP API에서 실행한다.
prometheus_query() {
  local expression="$1" # 실행할 PromQL을 저장한다.

  curl \
    "${CURL_OPTIONS[@]}" \
    --get \
    --header "Host: ${PROMETHEUS_HOST}" \
    --data-urlencode "query=${expression}" \
    "${PROMETHEUS_URL}/api/v1/query"
}

# 지정한 경고가 inactive, pending, firing 중 어떤 상태인지 확인한다.
get_prometheus_alert_state() {
  local alert_name="$1" # 확인할 경고 이름을 저장한다.
  local expression # Prometheus에 전달할 PromQL을 저장한다.
  local response # Prometheus API 응답을 저장한다.
  local state # 응답에서 추출한 경고 상태를 저장한다.

  expression="ALERTS{alertname=\"${alert_name}\",namespace=\"platform-lab\",service=\"platform-app\"}" # 해당 애플리케이션의 특정 경고만 조회한다.

  if ! response="$(prometheus_query "${expression}")"; then # Prometheus API 요청 성공 여부를 확인한다.
    echo "[FAIL] Could not query Prometheus alert: ${alert_name}" >&2
    return 1
  fi

  state="$(
    jq -r '
      if .status != "success" then
        "query-error"
      elif (.data.result | length) == 0 then
        "inactive"
      else
        [.data.result[].metric.alertstate]
        | unique
        | join(",")
      end
    ' <<< "${response}"
  )" # 조회 결과가 없으면 inactive, 있으면 alertstate 값을 가져온다.

  echo "${state}" # 호출한 함수가 사용할 수 있도록 경고 상태만 출력한다.
}

# Alertmanager 활성 목록에 지정한 경고가 존재하는지 확인한다.
get_alertmanager_alert_state() {
  local alert_name="$1" # 확인할 경고 이름을 저장한다.
  local response # Alertmanager API 응답을 저장한다.

  if ! response="$(
    curl \
      "${CURL_OPTIONS[@]}" \
      --header "Host: ${ALERTMANAGER_HOST}" \
      "${ALERTMANAGER_URL}/api/v2/alerts?active=true&silenced=true&inhibited=true&unprocessed=true"
  )"; then # Alertmanager API 요청 성공 여부를 확인한다.
    echo "[FAIL] Could not query Alertmanager alert: ${alert_name}" >&2
    return 1
  fi

  if ! jq -e 'type == "array"' <<< "${response}" > /dev/null; then # Alertmanager 응답이 JSON 배열인지 확인한다.
    echo "[FAIL] Alertmanager returned an invalid response." >&2
    return 1
  fi

  if jq \
    -e \
    --arg alert_name "${alert_name}" \
    'any(
      .[];
      .labels.alertname == $alert_name
      and .labels.namespace == "platform-lab"
      and .labels.service == "platform-app"
    )' \
    <<< "${response}" \
    > /dev/null; then

    echo "active" # 일치하는 활성 경고가 있으면 active를 반환한다.
  else
    echo "inactive" # 일치하는 활성 경고가 없으면 inactive를 반환한다.
  fi
}

# Prometheus에 등록된 전체 Recording Rule과 Alert Rule을 조회한다.
load_prometheus_rules() {
  if ! PROMETHEUS_RULES_JSON="$(
    curl \
      "${CURL_OPTIONS[@]}" \
      --header "Host: ${PROMETHEUS_HOST}" \
      "${PROMETHEUS_URL}/api/v1/rules"
  )"; then # 전체 규칙 JSON을 전역 변수에 저장한다.
    echo "[FAIL] Failed to load Prometheus rules." >&2
    exit 1
  fi

  if jq -e '.status == "success"' <<< "${PROMETHEUS_RULES_JSON}" > /dev/null; then # Prometheus API 응답이 성공인지 확인한다.
    echo "[PASS] Prometheus rules API responded successfully."
  else
    echo "[FAIL] Prometheus rules API returned an invalid response." >&2
    exit 1
  fi
}

# 지정한 규칙이 Prometheus에 로드되어 있는지 확인한다.
check_prometheus_rule() {
  local rule_name="$1" # 확인할 규칙 이름을 저장한다.

  if jq \
    -e \
    --arg rule_name "${rule_name}" \
    'any(.data.groups[].rules[]?; .name == $rule_name)' \
    <<< "${PROMETHEUS_RULES_JSON}" \
    > /dev/null; then

    echo "[PASS] Prometheus rule loaded: ${rule_name}"
  else
    echo "[FAIL] Prometheus rule not found: ${rule_name}" >&2
    return 1
  fi
}

# 지정한 경고가 테스트 시작 전에 inactive 상태인지 확인한다.
check_alert_inactive() {
  local alert_name="$1" # 확인할 경고 이름을 저장한다.
  local alert_state # Prometheus의 경고 상태를 저장한다.
  local alertmanager_state # Alertmanager의 경고 상태를 저장한다.

  alert_state="$(get_prometheus_alert_state "${alert_name}")" # Prometheus에서 현재 경고 상태를 조회한다.
  alertmanager_state="$(get_alertmanager_alert_state "${alert_name}")" # Alertmanager 활성 목록에서 경고 상태를 조회한다.

  if [[ "${alert_state}" == "inactive" ]]; then
    echo "[PASS] Prometheus alert is inactive: ${alert_name}"
  else
    echo "[FAIL] Prometheus alert is not inactive: ${alert_name} (state: ${alert_state})" >&2
    return 1
  fi

  if [[ "${alertmanager_state}" == "inactive" ]]; then
    echo "[PASS] Alertmanager alert is inactive: ${alert_name}"
  else
    echo "[FAIL] Alertmanager alert is still active: ${alert_name}" >&2
    return 1
  fi
}

# 현재 시나리오에서 필요한 규칙과 초기 경고 상태를 검사한다.
check_scenario_ready() {
  local rule_name # 현재 검사 중인 규칙 이름을 저장한다.
  local alert_name # 현재 검사 중인 경고 이름을 저장한다.

  echo
  echo "Checking ${CURRENT_SCENARIO} rules and alert states..."
  echo "==========================="

  for rule_name in "${REQUIRED_ALERTS[@]}"; do # 현재 시나리오의 필수 Alert Rule을 검사한다.
    check_prometheus_rule "${rule_name}"
  done

  for rule_name in "${REQUIRED_RECORDING_RULES[@]}"; do # 현재 시나리오의 필수 Recording Rule을 검사한다.
    check_prometheus_rule "${rule_name}"
  done

  for alert_name in "${REQUIRED_ALERTS[@]}"; do # 이전 실행에서 남은 경고가 없는지 확인한다.
    check_alert_inactive "${alert_name}"
  done
}

# 현재 선택된 시나리오의 k6 테스트를 백그라운드에서 실행한다.
start_k6_test() {
  if [[ ! -f "${K6_SCRIPT}" ]]; then # configure_scenario에서 선택한 k6 파일이 존재하는지 확인한다.
    echo "[FAIL] k6 test script not found: ${K6_SCRIPT}" >&2
    return 1
  fi

  CURRENT_K6_LOG="$(mktemp)" # k6 출력을 저장할 임시 파일을 생성한다.

  # k6 출력을 임시 파일로 보내고 테스트를 백그라운드에서 실행한다.
  k6 run \
    -e TARGET_HOST="${K6_TARGET_HOST}" \
    -e BASE_URL="${K6_BASE_URL}" \
    "${K6_SCRIPT}" \
    > "${CURRENT_K6_LOG}" 2>&1 &

  CURRENT_K6_PID=$! # 가장 최근에 백그라운드로 실행한 k6 프로세스 ID를 저장한다.

  echo
  echo "[INFO] Started ${CURRENT_SCENARIO} test."
  echo "[INFO] k6 PID: ${CURRENT_K6_PID}"
}

# 현재 시나리오의 모든 필수 경고가 Prometheus에서 firing이 될 때까지 기다린다.
wait_for_prometheus_alerts_firing() {
  local deadline # FIRING 대기를 종료할 Unix 시간을 저장한다.
  local alert_name # 현재 검사 중인 경고 이름을 저장한다.
  local alert_state # 현재 검사 중인 경고 상태를 저장한다.
  local missing_count # 아직 firing이 아닌 경고 개수를 저장한다.

  deadline=$(( $(date +%s) + FIRING_TIMEOUT_SECONDS )) # 현재 시각을 기준으로 FIRING 대기 종료 시각을 계산한다.

  echo
  echo "Waiting for ${CURRENT_SCENARIO} alerts in Prometheus..."
  echo "==========================="

  while (( $(date +%s) <= deadline )); do # 제한 시간을 넘지 않는 동안 상태를 반복 조회한다.
    missing_count=0 # 조회 주기마다 미발생 경고 개수를 초기화한다.

    for alert_name in "${REQUIRED_ALERTS[@]}"; do # 현재 시나리오의 필수 경고를 차례대로 검사한다.
      alert_state="$(get_prometheus_alert_state "${alert_name}")" # Prometheus에서 현재 경고 상태를 조회한다.

      echo "[INFO] Current Prometheus state: ${alert_name}=${alert_state}"

      if [[ "${alert_state}" != "firing" ]]; then # 현재 경고가 firing이 아니면 미발생 개수를 증가시킨다.
        missing_count=$(( missing_count + 1 ))
      fi
    done

    if (( missing_count == 0 )); then # 모든 필수 경고가 firing 상태인지 확인한다.
      echo "[PASS] All ${CURRENT_SCENARIO} alerts are firing in Prometheus."
      return 0
    fi

    if ! kill -0 "${CURRENT_K6_PID}" 2> /dev/null; then # FIRING 완료 전에 k6가 종료됐는지 확인한다.
      echo "[FAIL] k6 ended before all alerts reached firing." >&2
      tail -n 40 "${CURRENT_K6_LOG}" >&2
      return 1
    fi

    sleep "${POLL_INTERVAL_SECONDS}" # 다음 조회 전까지 지정된 시간만큼 기다린다.
  done

  echo "[FAIL] Alerts did not reach firing within ${FIRING_TIMEOUT_SECONDS} seconds." >&2
  tail -n 40 "${CURRENT_K6_LOG}" >&2
  return 1
}

# 모든 필수 경고가 Alertmanager 활성 목록에 나타날 때까지 기다린다.
wait_for_alertmanager_alerts_active() {
  local deadline # Alertmanager 전달 대기를 종료할 Unix 시간을 저장한다.
  local alert_name # 현재 검사 중인 경고 이름을 저장한다.
  local alert_state # Alertmanager에서 조회한 경고 상태를 저장한다.
  local missing_count # Alertmanager에 아직 도착하지 않은 경고 개수를 저장한다.

  deadline=$(( $(date +%s) + ALERTMANAGER_TIMEOUT_SECONDS )) # Alertmanager 전달 대기 종료 시각을 계산한다.

  echo
  echo "Waiting for ${CURRENT_SCENARIO} alerts in Alertmanager..."
  echo "==========================="

  while (( $(date +%s) <= deadline )); do # 제한 시간을 넘지 않는 동안 Alertmanager를 반복 조회한다.
    missing_count=0 # 조회 주기마다 미도착 경고 개수를 초기화한다.

    for alert_name in "${REQUIRED_ALERTS[@]}"; do # 현재 시나리오의 필수 경고를 차례대로 검사한다.
      alert_state="$(get_alertmanager_alert_state "${alert_name}")" # Alertmanager 활성 목록에서 경고 상태를 조회한다.

      echo "[INFO] Current Alertmanager state: ${alert_name}=${alert_state}"

      if [[ "${alert_state}" != "active" ]]; then # 경고가 활성 목록에 없으면 미도착 개수를 증가시킨다.
        missing_count=$(( missing_count + 1 ))
      fi
    done

    if (( missing_count == 0 )); then # 모든 필수 경고가 Alertmanager에 도착했는지 확인한다.
      echo "[PASS] All ${CURRENT_SCENARIO} alerts are present in Alertmanager."
      return 0
    fi

    sleep "${POLL_INTERVAL_SECONDS}" # 다음 조회 전까지 지정된 시간만큼 기다린다.
  done

  echo "[FAIL] Alerts did not reach Alertmanager within ${ALERTMANAGER_TIMEOUT_SECONDS} seconds." >&2
  return 1
}

# 선택 사항인 Sustained Burn 경고 상태를 정보로만 출력한다.
show_optional_alert_states() {
  local alert_name # 확인할 선택 경고 이름을 저장한다.
  local alert_state # 선택 경고의 Prometheus 상태를 저장한다.

  for alert_name in "${OPTIONAL_ALERTS[@]}"; do # 현재 시나리오의 선택 경고를 차례대로 확인한다.
    alert_state="$(get_prometheus_alert_state "${alert_name}")" # 선택 경고의 현재 상태를 조회한다.
    echo "[INFO] Optional alert state: ${alert_name}=${alert_state}"
  done
}

# k6 테스트가 종료될 때까지 기다린 후 실행 결과를 출력한다.
wait_for_k6_completion() {
  local k6_status # k6 프로세스의 종료 코드를 저장한다.

  if wait "${CURRENT_K6_PID}"; then # 백그라운드 k6 프로세스가 종료될 때까지 기다린다.
    k6_status=0
  else
    k6_status=$? # k6가 실패했다면 반환된 종료 코드를 저장한다.
  fi

  CURRENT_K6_PID="" # 종료된 프로세스가 cleanup에서 다시 처리되지 않도록 초기화한다.

  echo
  echo "k6 results"
  echo "==========================="
  tail -n 40 "${CURRENT_K6_LOG}" # k6 로그의 마지막 40줄을 출력한다.

  if (( k6_status != 0 )); then # k6 종료 코드가 0이 아니면 테스트 실패로 처리한다.
    echo "[FAIL] k6 ${CURRENT_SCENARIO} test failed with exit code ${k6_status}." >&2
    return 1
  fi

  echo "[PASS] k6 ${CURRENT_SCENARIO} test completed successfully."
}

# 현재 시나리오의 모든 필수 경고가 Prometheus에서 inactive 상태로 돌아올 때까지 기다린다.
wait_for_prometheus_alerts_resolved() {
  local deadline # RESOLVED 대기를 종료할 Unix 시간을 저장한다.
  local alert_name # 현재 검사 중인 경고 이름을 저장한다.
  local alert_state # 현재 검사 중인 경고 상태를 저장한다.
  local active_count # 아직 활성 상태인 경고 개수를 저장한다.

  deadline=$(( $(date +%s) + RESOLVED_TIMEOUT_SECONDS )) # 현재 시각을 기준으로 RESOLVED 대기 종료 시각을 계산한다.

  echo
  echo "Waiting for ${CURRENT_SCENARIO} alerts to resolve in Prometheus..."
  echo "==========================="

  while (( $(date +%s) <= deadline )); do # 제한 시간을 넘지 않는 동안 경고 상태를 반복 조회한다.
    active_count=0 # 조회 주기마다 활성 경고 개수를 초기화한다.

    for alert_name in "${REQUIRED_ALERTS[@]}"; do # 현재 시나리오의 필수 경고를 차례대로 검사한다.
      alert_state="$(get_prometheus_alert_state "${alert_name}")" # Prometheus에서 현재 경고 상태를 조회한다.

      echo "[INFO] Current Prometheus state: ${alert_name}=${alert_state}"

      if [[ "${alert_state}" != "inactive" ]]; then # 경고가 pending 또는 firing이면 활성 개수를 증가시킨다.
        active_count=$(( active_count + 1 ))
      fi
    done

    if (( active_count == 0 )); then # 모든 필수 경고가 inactive 상태인지 확인한다.
      echo "[PASS] All ${CURRENT_SCENARIO} alerts are resolved in Prometheus."
      return 0
    fi

    sleep "${POLL_INTERVAL_SECONDS}" # 다음 조회 전까지 지정된 시간만큼 기다린다.
  done

  echo "[FAIL] Alerts did not resolve within ${RESOLVED_TIMEOUT_SECONDS} seconds." >&2
  return 1
}

# 모든 필수 경고가 Alertmanager 활성 목록에서도 사라질 때까지 기다린다.
wait_for_alertmanager_alerts_resolved() {
  local deadline # Alertmanager 해제 대기를 종료할 Unix 시간을 저장한다.
  local alert_name # 현재 검사 중인 경고 이름을 저장한다.
  local alert_state # Alertmanager에서 조회한 경고 상태를 저장한다.
  local active_count # Alertmanager에 아직 남아 있는 경고 개수를 저장한다.

  deadline=$(( $(date +%s) + ALERTMANAGER_TIMEOUT_SECONDS )) # Alertmanager 해제 대기 종료 시각을 계산한다.

  echo
  echo "Waiting for ${CURRENT_SCENARIO} alerts to resolve in Alertmanager..."
  echo "==========================="

  while (( $(date +%s) <= deadline )); do # 제한 시간을 넘지 않는 동안 Alertmanager를 반복 조회한다.
    active_count=0 # 조회 주기마다 활성 경고 개수를 초기화한다.

    for alert_name in "${REQUIRED_ALERTS[@]}"; do # 현재 시나리오의 필수 경고를 차례대로 검사한다.
      alert_state="$(get_alertmanager_alert_state "${alert_name}")" # Alertmanager 활성 목록에서 경고 상태를 조회한다.

      echo "[INFO] Current Alertmanager state: ${alert_name}=${alert_state}"

      if [[ "${alert_state}" == "active" ]]; then # 경고가 아직 활성 목록에 남아 있으면 개수를 증가시킨다.
        active_count=$(( active_count + 1 ))
      fi
    done

    if (( active_count == 0 )); then # 모든 필수 경고가 Alertmanager 활성 목록에서 사라졌는지 확인한다.
      echo "[PASS] All ${CURRENT_SCENARIO} alerts are resolved in Alertmanager."
      return 0
    fi

    sleep "${POLL_INTERVAL_SECONDS}" # 다음 조회 전까지 지정된 시간만큼 기다린다.
  done

  echo "[FAIL] Alerts remained active in Alertmanager for more than ${ALERTMANAGER_TIMEOUT_SECONDS} seconds." >&2
  return 1
}

# 하나의 시나리오에 대해 전체 경고 회귀 테스트를 수행한다.
run_scenario() {
  local scenario="$1" # 실행할 시나리오 이름을 저장한다.

  configure_scenario "${scenario}" # 시나리오에 맞는 k6 파일과 경고 목록을 설정한다.
  check_scenario_ready # 필요한 규칙과 기존 경고 상태를 확인한다.
  start_k6_test # 선택된 k6 테스트를 백그라운드에서 실행한다.
  wait_for_prometheus_alerts_firing # 필수 경고가 Prometheus에서 firing이 될 때까지 기다린다.
  wait_for_alertmanager_alerts_active # 필수 경고가 Alertmanager에 전달될 때까지 기다린다.
  show_optional_alert_states # Sustained Burn 경고 상태를 참고 정보로 출력한다.
  wait_for_k6_completion # k6 테스트가 끝날 때까지 기다리고 결과를 확인한다.
  wait_for_prometheus_alerts_resolved # 필수 경고가 Prometheus에서 inactive가 될 때까지 기다린다.
  wait_for_alertmanager_alerts_resolved # 필수 경고가 Alertmanager 활성 목록에서 사라질 때까지 기다린다.

  echo
  echo "[PASS] ${CURRENT_SCENARIO} FIRING and RESOLVED regression test completed successfully in Prometheus and Alertmanager."

  rm -f -- "${CURRENT_K6_LOG}" # 정상 완료된 시나리오의 임시 로그 파일을 삭제한다.
  CURRENT_K6_LOG="" # cleanup 함수가 같은 파일을 다시 삭제하지 않도록 경로를 초기화한다.
}

# 전체 환경에 공통으로 필요한 사전 점검을 수행한다.
preflight_checks() {
  echo
  echo "Running preflight checks..."
  echo "==========================="

  require_command "curl"
  require_command "jq"
  require_command "k6"
  require_command "systemctl"
  require_command "timedatectl"

  check_ntp
  check_health
  check_endpoint "Prometheus" "${PROMETHEUS_URL}/-/ready" "${PROMETHEUS_HOST}"
  check_endpoint "Alertmanager" "${ALERTMANAGER_URL}/-/ready" "${ALERTMANAGER_HOST}"

  load_prometheus_rules # Prometheus Ready 상태를 확인한 후 전체 규칙을 한 번만 가져온다.

  echo
  echo "All preflight checks passed."
}

main() {
  local mode="${1:-latency}" # 실행 인자가 없으면 기존과 동일하게 latency 테스트를 실행한다.

  echo "Alert Regression Test"
  echo "====================="
  echo "Mode: ${mode}"
  echo "Application: ${K6_BASE_URL}"
  echo "Prometheus: ${PROMETHEUS_URL} (Host: ${PROMETHEUS_HOST})"
  echo "Alertmanager: ${ALERTMANAGER_URL} (Host: ${ALERTMANAGER_HOST})"

  case "${mode}" in
    -h|--help)
      usage
      return 0
      ;;

    latency|error-rate|all|check)
      ;;
      
    *)
      echo "[FAIL] Unsupported mode: ${mode}" >&2
      usage >&2
      return 1
      ;;
  esac

  preflight_checks # 애플리케이션과 모니터링 구성요소의 공통 사전 점검을 실행한다.

  case "${mode}" in
    latency)
      run_scenario "latency"
      ;;

    error-rate)
      run_scenario "error-rate"
      ;;

    all)
      run_scenario "latency"
      run_scenario "error-rate"
      ;;

    check)
      configure_scenario "latency"
      check_scenario_ready

      configure_scenario "error-rate"
      check_scenario_ready

      echo
      echo "[PASS] Alert regression preflight checks completed successfully."
      ;;
  esac

  if [[ "${mode}" != "check" ]]; then # 실제 테스트가 실행된 경우에만 Discord 수동 확인 안내를 출력한다.
    echo
    echo "[INFO] Manual check: confirm matching Discord FIRING and RESOLVED messages."
  fi
}

main "$@" # 실행할 때 전달된 모든 인자를 main 함수로 전달한다.
