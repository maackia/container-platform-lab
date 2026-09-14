# Prometheus·Alertmanager 경고 회귀 테스트

이 문서는 k6로 지연과 HTTP 5xx 조건을 재현하고, Prometheus와 Alertmanager에서 경고의 `FIRING → RESOLVED` 생명주기를 한 명령으로 검증하는 방법을 정리한다.

기존 부하 테스트는 사람이 Grafana와 Alertmanager 화면을 보면서 결과를 확인했다. 경고 회귀 테스트는 같은 조건을 반복 실행하고 필수 규칙, 초기 상태, 경고 발생, 전달, 복구를 스크립트가 자동으로 판정하도록 확장한 것이다.

```text
사전 점검
→ k6 장애 시나리오 시작
→ Prometheus FIRING 확인
→ Alertmanager 활성 경고 확인
→ k6 종료 상태 확인
→ Prometheus RESOLVED 확인
→ Alertmanager 활성 목록 제거 확인
→ Discord FIRING·RESOLVED 수동 확인
```

## 1. 자동 검증 범위

`scripts/run-alert-regression.sh`는 다음 항목을 검사한다.

- `curl`, `jq`, `k6`, `systemctl`, `timedatectl` 설치 여부
- Ubuntu `systemd-timesyncd`와 NTP 동기화 상태
- 애플리케이션 `/health` 응답
- Prometheus와 Alertmanager readiness
- 시나리오에 필요한 Alert Rule과 Recording Rule 로드 여부
- 테스트 시작 전 필수 경고가 Prometheus와 Alertmanager에서 비활성 상태인지 여부
- 각 시나리오 실행 전 최근 1시간 요청 이력과 Fast Burn 재현에 필요한 VU 수
- k6 실행 중 필수 경고의 Prometheus `firing` 전환
- FIRING 경고가 Alertmanager 활성 목록에 전달됐는지 여부
- k6 종료 코드와 threshold 통과 여부
- 부하 종료 후 Prometheus 경고의 `inactive` 전환
- 해제된 경고가 Alertmanager 활성 목록에서 제거됐는지 여부

Discord Webhook은 Alertmanager에서 Discord로 보내는 단방향 통신이다. 저장소에서 Discord 메시지 수신 결과를 다시 조회할 API가 없으므로 Discord의 FIRING·RESOLVED 메시지는 수동으로 확인한다.

## 2. 시나리오와 필수 경고

시나리오마다 k6 파일, 필수 경고, Recording Rule을 설정하고 나머지 실행 흐름은 공통 함수로 처리한다.

| 시나리오 | k6 파일 | 필수 경고 | 필수 Recording Rule |
|---|---|---|---|
| `latency` | `load-tests/latency.js` | `PlatformAppHighP95Latency` | `platform_app:slo_http_latency_burn_rate:5m` |
| `latency` | `load-tests/latency.js` | `PlatformAppHttpLatencyFastBurn` | `platform_app:slo_http_latency_burn_rate:1h` |
| `error-rate` | `load-tests/error-rate.js` | `PlatformAppHighErrorRate` | `platform_app:slo_http_success_burn_rate:5m` |
| `error-rate` | `load-tests/error-rate.js` | `PlatformAppHttpSuccessFastBurn` | `platform_app:slo_http_success_burn_rate:1h` |

다음 Sustained Burn 경고는 상태를 출력하지만 테스트 성공 조건에는 포함하지 않는다.

- `PlatformAppHttpLatencySustainedBurn`
- `PlatformAppHttpSuccessSustainedBurn`

Sustained Burn은 6시간·30분 창을 함께 사용한다. 현재 테스트뿐 아니라 이전 요청 이력의 영향을 받으므로 깨끗한 환경에서도 항상 같은 시점에 발생한다고 보장할 수 없다. 반면 Fast Burn은 현재 장애 시나리오로 재현하기 쉬워 필수 회귀 조건으로 사용한다. Fast Burn의 1시간 창에는 이전 정상·장애 요청도 포함되므로, 스크립트가 시나리오별 전체·느린·5xx 요청 수를 조회해 필요한 VU 수를 자동으로 조정한다.

## 3. 실행 전 준비

현재 주 실행 환경은 Ubuntu VM의 K3s다. 다음 조건이 준비되어 있어야 한다.

1. K3s와 Traefik이 실행 중이어야 한다.
2. `platform-lab` 애플리케이션과 모니터링 스택이 정상이어야 한다.
3. 실습 전용 `/slow`, `/error` 엔드포인트가 활성화되어 있어야 한다.
4. k6, curl, jq가 설치되어 있어야 한다.
5. Ubuntu 시간이 NTP와 동기화되어 있어야 한다.
6. 이전 테스트의 필수 경고가 모두 해제된 상태여야 한다.

애플리케이션의 실습 엔드포인트 설정은 다음 값으로 확인한다.

```yaml
LAB_TEST_ENDPOINTS_ENABLED: "true"
```

VM 절전이나 호스트 잠금 이후 시간이 어긋났다면 다음 명령으로 상태를 확인한다.

```bash
timedatectl status
systemctl is-active systemd-timesyncd
```

필요하면 시간 동기화 서비스를 다시 시작한 뒤 `System clock synchronized: yes`를 확인한다.

```bash
sudo systemctl restart systemd-timesyncd
timedatectl status
```

## 4. 주소와 Traefik Host 헤더

Ubuntu VM에서는 세 서비스 모두 `127.0.0.1`로 연결하고 HTTP `Host` 헤더로 Traefik Ingress를 선택한다.

| 대상 | 연결 주소 | Host 헤더 |
|---|---|---|
| 애플리케이션 | `http://127.0.0.1` | `app.platform.local` |
| Prometheus | `http://127.0.0.1` | `prometheus.platform.local` |
| Alertmanager | `http://127.0.0.1` | `alertmanager.platform.local` |

```text
run-alert-regression.sh
→ 127.0.0.1:80
→ Host 헤더
→ Traefik Ingress
├→ application
├→ Prometheus
└→ Alertmanager
```

따라서 Ubuntu의 `/etc/hosts`에 각 도메인을 추가하지 않아도 스크립트를 실행할 수 있다.

## 5. 실행 명령

가장 먼저 환경, 규칙, 초기 경고 상태만 검사한다. 이 모드는 k6를 실행하지 않는다.

```bash
make alert-regression-check
```

지연시간 경고만 검증한다.

```bash
make alert-regression-latency
```

HTTP 오류율 경고만 검증한다.

```bash
make alert-regression-error-rate
```

두 시나리오를 순차 실행한다.

```bash
make alert-regression
```

스크립트를 직접 실행할 수도 있다. 실행 인자를 생략하면 기존 동작과 동일하게 `latency`가 선택된다.

```bash
./scripts/run-alert-regression.sh
./scripts/run-alert-regression.sh latency
./scripts/run-alert-regression.sh error-rate
./scripts/run-alert-regression.sh all
./scripts/run-alert-regression.sh check
```

`all`은 latency가 완전히 RESOLVED된 다음 error-rate를 실행한다. 두 시나리오를 동시에 실행하지 않으므로 어떤 조건이 경고를 발생시켰는지 구분할 수 있다.

## 6. 시나리오 실행 흐름

### 사전 점검

공통 사전 점검 이후 시나리오별 필수 규칙과 초기 경고 상태를 확인한다.

```text
명령어 설치 확인
→ NTP 동기화 확인
→ application /health
→ Prometheus /-/ready
→ Alertmanager /-/ready
→ /api/v1/rules에서 필수 규칙 확인
→ Prometheus 필수 경고 inactive 확인
→ Alertmanager 필수 경고 inactive 확인
→ 최근 1시간 시나리오별 요청 이력 확인
→ latency 또는 error-rate Fast Burn 재현에 필요한 VU 계산
```

초기 경고가 남아 있으면 새로운 실행이 만든 경고와 이전 경고를 구분할 수 없으므로 테스트를 시작하지 않는다.

Latency Fast Burn은 1시간과 5분 Burn Rate가 모두 `14.4x`를 넘어야 한다. 지연시간 SLO의 허용 위반율은 5%이므로 최근 1시간의 느린 요청 비율이 72%를 넘어야 한다. 스크립트는 75%를 목표로 필요한 느린 요청 수를 계산하고, alert의 1분 `for` 구간이 시작되기 전까지 VU 한 명당 30개의 요청을 만드는 것으로 보수적으로 추정해 `LATENCY_VUS`를 결정한다.

HTTP Success Fast Burn은 1시간과 5분의 5xx 비율이 모두 14.4%를 넘어야 한다. 스크립트는 16%를 목표로 필요한 5xx 요청 수를 계산하고, 같은 시점까지 VU 한 명당 75개의 요청을 만드는 것으로 추정해 `ERROR_RATE_VUS`를 결정한다. `all` 모드에서도 error-rate를 시작하기 직전에 값을 다시 조회하므로 앞선 latency 요청이 1시간 분모에 포함된다.

계산된 값이 latency 30 VU 또는 error-rate 20 VU의 기본 안전 상한을 넘으면 부하를 무조건 실행하지 않고 사전 점검에서 실패한다. 이 경우 1시간 이력이 만료되기를 기다리는 것이 기본 대응이다.

### FIRING 검증

k6는 백그라운드에서 실행되고 스크립트는 Prometheus 상태를 주기적으로 조회한다.

```text
inactive
→ pending
→ firing
```

필수 경고가 모두 `firing`이 되기 전에 k6가 종료되면 테스트는 실패한다. Prometheus FIRING 이후에는 Alertmanager `/api/v2/alerts`에서 같은 경고가 활성 상태인지 확인한다. Silence 또는 Inhibition 상태도 전달 자체는 성공한 것이므로 조회 대상에 포함한다.

### RESOLVED 검증

k6 종료와 경고 해제는 동시에 일어나지 않는다. Prometheus의 범위 벡터에 장애 요청이 남아 있는 동안에는 조건이 계속 참일 수 있다.

```text
k6 종료
→ scrape 주기 경과
→ Recording Rule 평가
→ 짧은 범위에서 장애 요청 제외
→ Alert Rule inactive
→ Alertmanager 활성 목록에서 제거
```

일반 p95·오류율 경고가 먼저 해제되고 5분 Fast Burn 경고가 나중에 해제되는 것은 정상이다. 스크립트는 모든 필수 경고가 해제될 때까지 기다린다.

## 7. 제한 시간 설정

다음 환경 변수로 조회 간격과 제한 시간을 조정할 수 있다.

| 환경 변수 | 기본값 | 의미 |
|---|---:|---|
| `POLL_INTERVAL_SECONDS` | 10초 | Prometheus·Alertmanager 상태 조회 간격 |
| `FIRING_TIMEOUT_SECONDS` | 240초 | Prometheus FIRING 대기 시간 |
| `ALERTMANAGER_TIMEOUT_SECONDS` | 120초 | Alertmanager 전달·제거 대기 시간 |
| `RESOLVED_TIMEOUT_SECONDS` | 600초 | Prometheus RESOLVED 대기 시간 |
| `LATENCY_MIN_VUS` | 3 | latency 시나리오의 최소 VU 수 |
| `LATENCY_MAX_VUS` | 30 | 자동으로 허용할 latency VU 안전 상한 |
| `LATENCY_REQUESTS_PER_VU` | 30 | alert의 `for` 구간 전 VU당 예상 느린 요청 수 |
| `LATENCY_TARGET_VIOLATION_RATIO` | 0.75 | 1시간 지연 위반 비율 목표값 |
| `ERROR_RATE_MIN_VUS` | 2 | error-rate 시나리오의 최소 VU 수 |
| `ERROR_RATE_MAX_VUS` | 20 | 자동으로 허용할 error-rate VU 안전 상한 |
| `ERROR_RATE_REQUESTS_PER_VU` | 75 | alert의 `for` 구간 전 VU당 예상 5xx 요청 수 |
| `ERROR_RATE_TARGET_FAILURE_RATIO` | 0.16 | 1시간 5xx 비율 목표값 |

예를 들어 RESOLVED를 최대 12분 기다리려면 다음과 같이 실행한다.

```bash
RESOLVED_TIMEOUT_SECONDS=720 make alert-regression-latency
```

제한 시간은 Unix epoch 초인 `date +%s`를 기준으로 계산한다. `%S`는 현재 분 안의 초만 반환하므로 0부터 59까지 반복되며 제한 시간 계산에 사용할 수 없다.

```bash
deadline=$(( $(date +%s) + RESOLVED_TIMEOUT_SECONDS ))
```

## 8. 출력 해석

성공한 latency 실행은 다음 순서로 진행된다.

```text
[PASS] Prometheus rule loaded
[PASS] Prometheus alert is inactive
[INFO] Started latency test
[PASS] All latency alerts are firing in Prometheus
[PASS] All latency alerts are present in Alertmanager
[PASS] k6 latency test completed successfully
[PASS] All latency alerts are resolved in Prometheus
[PASS] All latency alerts are resolved in Alertmanager
```

error-rate 테스트에서 HTTP 500은 의도한 응답이다. k6의 `http_req_failed=0%`는 테스트가 예상하지 못한 실패가 없다는 뜻이며, 애플리케이션의 `app_http_requests_total{status_code="500"}` 증가와 모순되지 않는다. 자세한 차이는 [k6 부하 테스트와 경고 검증](./12-load-testing.md)에 정리한다.

## 9. 실패 시 점검

### 사전 점검에서 실패

```bash
make alert-regression-check
```

- NTP 실패: `timedatectl status`와 `systemctl is-active systemd-timesyncd`를 확인한다.
- health 실패: 애플리케이션 Pod, Service, Ingress와 `/health`를 확인한다.
- readiness 실패: Prometheus 또는 Alertmanager Pod와 probe 이벤트를 확인한다.
- rule not found: PrometheusRule 적용 여부와 Prometheus Rule Health를 확인한다.
- alert still active: 이전 테스트의 필수 경고가 해제될 때까지 기다린다.
- scenario load exceeds safe limit: 최근 1시간 정상 요청이 만료되기를 기다리거나, 실습 환경의 수용 범위를 확인한 후 `LATENCY_MAX_VUS` 또는 `ERROR_RATE_MAX_VUS`를 명시적으로 조정한다.

### FIRING 제한 시간 초과

- k6가 끝까지 실행 중이었는지 확인한다.
- `LAB_TEST_ENDPOINTS_ENABLED`가 `true`인지 확인한다.
- Grafana 또는 Prometheus에서 `/slow`, `/error` 메트릭이 증가하는지 확인한다.
- Recording Rule 값과 Alert Rule의 `pending` 여부를 확인한다.

### RESOLVED 제한 시간 초과

- `date +%s`로 제한 시간을 계산하는지 확인한다.
- VM과 Prometheus의 시간이 어긋나지 않았는지 확인한다.
- Fast Burn 계산에 사용하는 5분 범위에 장애 요청이 아직 남아 있는지 확인한다.
- Alertmanager 실패인지 구분하기 위해 Prometheus의 `ALERTS` 상태를 먼저 확인한다.

### 실행 중 중단

`Ctrl+C` 또는 오류로 스크립트가 종료되면 `trap`에 등록된 정리 함수가 백그라운드 k6 프로세스를 종료하고 임시 로그 파일을 삭제한다.

## 10. CI와 수동 확인 범위

이 회귀 테스트는 실제 K3s의 Prometheus, Alertmanager와 실습용 장애 엔드포인트가 필요하고 한 번 실행하는 데 시간이 오래 걸리므로 기본 GitHub Actions에서는 실행하지 않는다.

```text
GitHub Actions
→ k6 스크립트 문법 검사
→ Compose smoke test

Ubuntu K3s
→ make alert-regression-check
→ make alert-regression
→ Discord 메시지 수동 확인
```

자동화의 성공은 Prometheus와 Alertmanager의 상태 생명주기를 보장한다. 최종 운영 경로 검증에서는 Discord에서 latency와 error-rate의 FIRING·RESOLVED 메시지가 각각 도착했는지 추가로 확인한다.

## 11. 검증 결과

Ubuntu K3s 환경에서 다음 실행을 확인했다.

```text
check
→ latency·error-rate 필수 규칙 로드 확인
→ Prometheus·Alertmanager 초기 비활성 상태 확인

latency
→ p95 약 1.5초
→ PlatformAppHighP95Latency FIRING / RESOLVED
→ PlatformAppHttpLatencyFastBurn FIRING / RESOLVED

error-rate
→ expected HTTP 500 응답 300회
→ PlatformAppHighErrorRate FIRING / RESOLVED
→ PlatformAppHttpSuccessFastBurn FIRING / RESOLVED

all
→ latency 완료·해제 후 error-rate 순차 실행
→ Prometheus·Alertmanager 전체 검증 통과
```

Sustained Burn 경고도 테스트 시점의 이력에 따라 함께 관찰됐지만, 재현성이 다른 선택 경고로 분리해 결과만 출력했다.
