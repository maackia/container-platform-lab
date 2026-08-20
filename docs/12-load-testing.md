# k6 부하 테스트와 경고 검증

이 문서는 k6로 정상·지연·오류 트래픽을 반복해서 만들고, 애플리케이션 메트릭부터 PrometheusRule, Alertmanager, Discord까지 이어지는 경고 흐름을 검증한 과정을 정리한다.

```text
k6
→ Traefik Ingress
→ Node.js application
→ /metrics
→ ServiceMonitor
→ Prometheus
├→ Grafana
└→ PrometheusRule
   → Alertmanager
   → Discord FIRING / RESOLVED
```

## 1. 실습 환경과 버전

```text
k6: 2.2.0
Architecture: linux/arm64
Target: K3s platform-lab application
Ingress host: app.platform.local
Prometheus scrape interval: 15s
Prometheus evaluation interval: 15s
```

테스트와 CI가 같은 k6 동작을 사용하도록 로컬 바이너리와 GitHub Actions의 컨테이너 이미지를 `2.2.0`으로 맞춘다. 버전을 올릴 때는 [k6 공식 릴리스](https://github.com/grafana/k6/releases)와 [설치 문서](https://grafana.com/docs/k6/latest/set-up/install-k6/)를 확인하고, 로컬 실행과 CI 이미지를 함께 변경한다.

## 2. Ubuntu ARM64에 설치

이 실습의 Ubuntu ARM64 환경에서는 k6 APT 저장소가 `binary-arm64` 패키지를 제공하지 않아 패키지를 건너뛰었다. 따라서 공식 릴리스의 ARM64 archive를 내려받고 checksum을 검증한 뒤 설치했다.

```bash
K6_VERSION="2.2.0"
K6_ARCHIVE="k6-v${K6_VERSION}-linux-arm64.tar.gz"
K6_TEMP_DIR="$(mktemp -d)"

cd "$K6_TEMP_DIR"

curl -fLO \
  "https://github.com/grafana/k6/releases/download/v${K6_VERSION}/${K6_ARCHIVE}"

curl -fLO \
  "https://github.com/grafana/k6/releases/download/v${K6_VERSION}/k6-v${K6_VERSION}-checksums.txt"

grep " ${K6_ARCHIVE}$" \
  "k6-v${K6_VERSION}-checksums.txt" \
  | sha256sum --check

tar -xzf "$K6_ARCHIVE"

sudo install -m 0755 \
  "k6-v${K6_VERSION}-linux-arm64/k6" \
  /usr/local/bin/k6
```

설치 결과를 확인한다.

```bash
command -v k6
k6 version
file /usr/local/bin/k6
```

목표 결과는 `k6 v2.2.0`과 `ARM aarch64`다. checksum 검증이 실패하면 파일을 설치하지 않고 다운로드 출처와 파일명을 다시 확인한다.

## 3. 대상 주소와 HTTP Host 헤더

테스트는 Ubuntu VM에서 Traefik의 로컬 HTTP 포트로 연결하고, `Host` 헤더로 실제 Ingress 경로를 선택한다.

```text
Connection address: http://127.0.0.1
HTTP Host header:   app.platform.local
```

```text
k6 → 127.0.0.1:80
   → Host: app.platform.local
   → Traefik
   → platform-lab/app Service
   → application Pod
```

Makefile의 기본값은 다음과 같다.

```makefile
K6_BASE_URL ?= http://127.0.0.1
K6_TARGET_HOST ?= app.platform.local
```

환경이 다르면 실행 시 값을 덮어쓴다.

```bash
make load-test-smoke \
  K6_BASE_URL=http://127.0.0.1 \
  K6_TARGET_HOST=app.platform.local
```

## 4. 시나리오 구성

시나리오는 `load-tests/`에 분리한다.

| 파일 | 목적 | 기본 부하 | 대상 경로 |
|---|---|---|---|
| `smoke.js` | 연결과 기본 응답 확인 | 1 VU, 1회 | `/health` |
| `baseline.js` | 정상 상태의 기준 성능 확인 | 최대 5 VU, 2분 | `/` |
| `latency.js` | p95 지연 경고 재현 | 최대 3 VU, 3분 | `/slow` |
| `error-rate.js` | HTTP 5xx 오류율 경고 재현 | 최대 2 VU, 3분 | `/error` |

`/slow`와 `/error`는 운영 기능이 아니라 관측성과 경고를 검증하기 위한 실습 전용 엔드포인트다. K3s의 `platform-config`에는 다음 값이 있어야 한다.

```yaml
LAB_TEST_ENDPOINTS_ENABLED: "true"
```

기본 Compose 환경의 `.env.example`은 이 값을 `false`로 두므로 지연·오류 시나리오를 그대로 실행할 수 없다. 외부에 공개된 환경에서는 실습 엔드포인트를 활성화하지 않는다.

## 5. 실행 명령

먼저 모든 JavaScript 파일을 k6가 해석할 수 있는지 확인한다.

```bash
make load-test-validate
```

가장 짧은 smoke test로 연결을 확인한다.

```bash
make load-test-smoke
```

정상 상태의 기준 부하는 다음과 같이 실행한다.

```bash
make load-test-baseline
```

p95 지연과 HTTP 5xx 경고를 각각 재현한다.

```bash
make load-test-latency
make load-test-error-rate
```

지연·오류 테스트를 동시에 실행하면 어떤 시나리오가 경고를 발생시켰는지 구분하기 어려워질 수 있다. 한 시나리오를 실행하고 FIRING·RESOLVED까지 확인한 뒤 다음 시나리오로 넘어간다.

## 6. k6 결과 해석

k6 출력에서 주로 확인할 값은 다음과 같다.

| 항목 | 의미 |
|---|---|
| `checks` | `check()`에 선언한 응답 조건의 성공 비율 |
| `http_req_duration` | k6가 관찰한 HTTP 응답 시간 |
| `http_req_failed` | k6가 예상하지 못한 HTTP 실패 비율 |
| `http_reqs` | 전체 HTTP 요청 수와 초당 요청 수 |
| `iterations` | 가상 사용자가 시나리오 함수를 완료한 횟수 |
| `vus`, `vus_max` | 현재·최대 가상 사용자 수 |

baseline의 합격 기준은 정상 상태를 보호하기 위한 기준이다.

```javascript
checks: ["rate>0.99"]
http_req_failed: ["rate<0.01"]
http_req_duration: ["p(95)<500"]
```

반면 latency는 장애 조건을 의도적으로 만드는 시나리오다. 이 테스트에서 `p(95)>1000`은 성능 목표가 아니라 p95 경고 조건을 충분히 재현했다는 뜻이다.

```javascript
"http_req_duration{test_type:latency}": ["p(95)>1000"]
```

error-rate 시나리오는 HTTP 500을 의도한 응답으로 취급한다.

```javascript
const expectedErrorResponse = http.expectedStatuses(500);
```

따라서 결과의 `http_req_failed`는 0%일 수 있지만 애플리케이션의 `app_http_requests_total{status_code="500"}`은 증가한다. 두 값은 서로 다른 관점이다.

```text
k6 http_req_failed
→ 테스트가 예상한 응답인지 판단

app_http_requests_total
→ 애플리케이션이 실제로 반환한 HTTP 상태 기록
```

## 7. Prometheus와 Grafana 확인

애플리케이션 target이 정상인지 먼저 확인한다.

```promql
up{namespace="platform-lab", job="app"}
```

요청률은 다음 쿼리로 확인한다.

```promql
sum by (route, status_code) (
  rate(app_http_requests_total{
    namespace="platform-lab",
    job="app"
  }[2m])
)
```

route별 p95 응답 시간은 Histogram bucket으로 계산한다.

```promql
histogram_quantile(
  0.95,
  sum by (le, route) (
    rate(app_http_request_duration_seconds_bucket{
      namespace="platform-lab",
      job="app",
      route!~"/health|/metrics"
    }[2m])
  )
)
```

HTTP 5xx 비율은 전체 사용자 요청률과 5xx 요청률의 비율로 계산한다.

```promql
100 *
(
  sum(rate(app_http_requests_total{
    namespace="platform-lab",
    job="app",
    route!~"/health|/metrics",
    status_code=~"5.."
  }[2m])) or vector(0)
)
/
clamp_min(
  sum(rate(app_http_requests_total{
    namespace="platform-lab",
    job="app",
    route!~"/health|/metrics"
  }[2m])),
  0.001
)
```

Prometheus의 수집·규칙 평가 주기는 다음처럼 15초로 설정했다.

```yaml
prometheus:
  prometheusSpec:
    scrapeInterval: 15s
    evaluationInterval: 15s
    scrapeTimeout: 10s
```

15초 주기는 부하가 변하는 모습을 빠르게 관찰하기 위한 단일 노드 학습 환경 설정이다. 주기를 줄일수록 Prometheus와 대상 애플리케이션의 CPU·네트워크 사용량은 증가한다.

## 8. 경고와 Discord 검증

latency 시나리오의 검증 흐름은 다음과 같다.

```text
make load-test-latency
→ Grafana p95 증가 확인
→ PlatformAppHighP95Latency Pending
→ 1분 조건 유지
→ Firing
→ Discord FIRING 수신
→ 부하 종료
→ Prometheus 평가 주기 경과
→ Discord RESOLVED 수신
```

error-rate 시나리오도 같은 순서로 확인한다.

```text
make load-test-error-rate
→ app_http_requests_total{status_code="500"} 증가
→ PlatformAppHighErrorRate Pending
→ Firing
→ Discord FIRING 수신
→ 부하 종료
→ Discord RESOLVED 수신
```

k6가 종료된 순간과 RESOLVED가 도착하는 순간은 같지 않다. 메트릭 범위, scrape interval, evaluation interval, Alertmanager group interval을 차례로 거치므로 일정한 지연이 생기는 것이 정상이다.

## 9. CI 범위

GitHub Actions는 다음 두 수준으로 k6를 검증한다.

```text
모든 load-tests/*.js
→ k6 inspect로 문법과 options 확인

smoke.js
→ Compose 스택 시작 후 실제 /health 요청 실행
```

baseline·latency·error-rate 시나리오는 CI에서 실행하지 않는다. 실행 시간이 길고, 지연과 오류를 의도적으로 발생시키며, 실제 K3s의 Prometheus·Alertmanager·Discord 흐름을 확인해야 하기 때문이다.

```text
CI
→ 빠르고 안전한 회귀 검사

수동 K3s 실습
→ 부하·대시보드·경고·알림의 전체 흐름 검사
```

## 10. 실습 검증 결과

현재 환경에서 확인한 대표 결과는 다음과 같다. 절대 수치는 VM 리소스와 네트워크 상태에 따라 달라질 수 있으므로 구조와 합격 여부를 중심으로 본다.

```text
smoke
→ 1회 요청 성공
→ checks 100%

baseline
→ 449 requests
→ p95 12.49ms
→ failed 0%

latency
→ 198 requests
→ p95 1.5s
→ PlatformAppHighP95Latency FIRING / RESOLVED 확인

error-rate
→ 300 expected HTTP 500 responses
→ k6 http_req_failed 0%
→ PlatformAppHighErrorRate FIRING / RESOLVED 확인
```

## 11. 다음 단계

부하를 반복해서 재현할 수 있게 되었으므로 다음에는 관측 쿼리와 서비스 목표를 코드로 정리한다.

```text
k6 반복 가능한 부하 시나리오
→ Recording Rule
→ SLI / SLO
→ Error Budget
→ burn-rate alert
→ 자동 경고 회귀 테스트
```

이 단계의 핵심은 높은 트래픽을 만드는 것 자체가 아니라, 같은 조건을 다시 실행하고 메트릭·대시보드·경고·복구가 의도대로 연결되는지 검증하는 것이다.
