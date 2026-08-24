# Recording Rule과 SLI/SLO·Error Budget

이 문서는 반복해서 사용하는 PromQL을 Recording Rule로 저장하고, 최근 1시간의 HTTP 성공률과 응답 지연을 SLI·SLO·Error Budget으로 표현한 과정을 정리한다.

```text
Application metrics
→ Prometheus Recording Rule
→ SLI
→ SLO와 비교
→ Error Budget
→ Grafana Dashboard
```

## 1. 핵심 개념

| 개념 | 의미 | 현재 실습 |
|---|---|---|
| Recording Rule | PromQL 결과를 주기적으로 계산해 새 시계열로 저장 | 요청률, 오류율, p95, SLI, Error Budget |
| SLI | 서비스 상태를 나타내는 실제 측정값 | HTTP 성공률, 1초 이내 응답 비율 |
| SLO | SLI에 대해 정한 목표 | 성공률 99%, 1초 이내 응답 95% |
| Error Budget | SLO가 허용하는 실패 여유 | 실패 1%, 1초 초과 5% |

Recording Rule은 긴 PromQL을 대시보드와 경고마다 다시 계산하지 않고 이름이 있는 메트릭처럼 재사용하게 한다.

```text
원본 메트릭 + 복잡한 PromQL
→ Prometheus가 15초마다 계산
→ platform_app:... 이름의 새 시계열
```

## 2. 리소스 구성

일반 운영 지표와 SLO 계산을 두 파일로 분리한다.

```text
k8s/monitoring/16-platform-app-recording-rules.yaml
→ 요청률, 5xx 요청률, 오류 비율, route별 p95, 가용 replica

k8s/monitoring/17-platform-app-slo-recording-rules.yaml
→ 최근 1시간 요청 수, 성공률 SLI, 지연 SLI, 남은 Error Budget
```

두 `PrometheusRule`에는 현재 Prometheus가 선택할 수 있도록 `release: monitoring` 라벨을 지정한다.

```yaml
metadata:
  labels:
    release: monitoring
```

적용 전에 정적 검증과 서버 측 검증을 실행한다.

```bash
kubeconform -strict -summary -ignore-missing-schemas k8s
kubectl apply --dry-run=server -f k8s/monitoring/
kubectl apply -f k8s/monitoring/
```

규칙이 로드되었는지 확인한다.

```bash
kubectl get prometheusrule -n platform-lab
```

Prometheus의 **Status → Rule health** 화면에서는 다음 그룹이 `OK`여야 한다.

```text
platform-app.recording-rules
platform-app.slo-recording-rules
```

## 3. 기본 Recording Rule

`16-platform-app-recording-rules.yaml`은 자주 쓰는 운영 쿼리를 다음 시계열로 저장한다.

| Recording Rule | 의미 | 단위 |
|---|---|---|
| `platform_app:http_requests:rate5m` | 최근 5분 사용자 요청률 | requests/s |
| `platform_app:http_5xx_requests:rate5m` | 최근 5분 HTTP 5xx 요청률 | requests/s |
| `platform_app:http_error_ratio:rate5m` | 전체 요청 중 5xx 비율 | 0~1 |
| `platform_app:http_request_duration_seconds:p95_5m` | route별 p95 응답 시간 | seconds |
| `platform_app:available_replicas` | 사용 가능한 앱 replica 수 | count |

`/health`와 `/metrics`는 사용자 트래픽이 아니므로 요청률·오류율·지연 계산에서 제외한다.

```promql
route!~"/health|/metrics"
```

## 4. SLI와 SLO

현재 실습은 빠르게 결과를 관찰할 수 있도록 rolling 1h 창을 사용한다.

### HTTP 성공률

```text
SLI = 1 - (최근 1시간 5xx 요청 수 / 최근 1시간 전체 요청 수)
SLO = 99%
허용 실패 비율 = 1%
```

저장 시계열:

```promql
platform_app:sli_http_success_ratio:1h
```

### 응답 지연

Histogram의 `le="1"` bucket은 1초 이하로 처리된 요청의 누적 개수다.

```text
SLI = 최근 1시간 1초 이하 요청 수 / 최근 1시간 전체 요청 수
SLO = 95%
허용 지연 비율 = 5%
```

저장 시계열:

```promql
platform_app:sli_http_latency_le_1s_ratio:1h
```

실습에서 사용하는 1시간은 개념 검증용이다. 실제 서비스에서는 트래픽 특성과 운영 정책에 따라 7일, 28일 또는 30일 같은 더 긴 창을 함께 사용한다.

## 5. Error Budget 계산

남은 Error Budget은 다음 비율로 계산한다.

```text
남은 Error Budget
= 1 - ((1 - 현재 SLI) / 허용 실패 비율)
```

성공률 SLO가 99%라면 허용 실패 비율은 `0.01`, 지연 SLO가 95%라면 허용 지연 비율은 `0.05`다.

```text
100%  → 허용량을 사용하지 않음
0%    → 허용량을 모두 사용함
음수  → 허용량을 초과함
```

예를 들어 `-1900%`는 표시 오류가 아니라 허용된 나쁜 요청의 20배를 사용했다는 뜻이다.

```text
1 - 20 = -19
-19 × 100 = -1900%
```

저장 시계열:

```promql
platform_app:slo_http_success_error_budget_remaining_ratio:1h
platform_app:slo_http_latency_error_budget_remaining_ratio:1h
```

## 6. 트래픽이 없을 때의 처리

전체 요청 수가 0이면 비율의 분모도 0이 된다. Recording Rule은 `or vector(0)`과 `clamp_min`으로 계산 자체가 사라지거나 0으로 나누는 것을 방지한다.

다만 요청이 없는 상태의 SLI는 실제 품질을 의미하지 않는다. Grafana의 SLI 패널은 다음 조건을 함께 사용해 트래픽이 있을 때만 값을 표시한다.

```promql
and on (namespace, service, window)
(
  platform_app:sli_http_requests:increase1h > 0
)
```

따라서 동작은 다음처럼 구분한다.

```text
Recording Rule
→ 계산 가능한 시계열을 안정적으로 유지

Grafana panel
→ 최근 1시간 요청이 없으면 No data로 표시
```

## 7. Prometheus 조회

최근 1시간 요청 수:

```promql
platform_app:sli_http_requests:increase1h
```

성공률과 지연 SLI를 백분율로 조회한다.

```promql
100 * platform_app:sli_http_success_ratio:1h
```

```promql
100 * platform_app:sli_http_latency_le_1s_ratio:1h
```

남은 Error Budget을 백분율로 조회한다.

```promql
100 * platform_app:slo_http_success_error_budget_remaining_ratio:1h
```

```promql
100 * platform_app:slo_http_latency_error_budget_remaining_ratio:1h
```

새 규칙을 적용한 직후에는 Prometheus의 다음 평가 주기까지 잠시 기다려야 한다. 규칙 상태가 `OK`인데도 결과가 없다면 최근 1시간에 사용자 요청이 있는지 먼저 확인한다.

## 8. Grafana 대시보드

`Platform App Overview`에는 다음 row를 추가했다.

```text
SLO & Error Budget (rolling 1h)
├→ Requests (rolling 1h)
├→ HTTP Success SLI (1h)
├→ Latency ≤ 1s SLI (1h)
├→ Success Error Budget Remaining
└→ Latency Error Budget Remaining
```

대시보드의 원본과 K3s provisioning ConfigMap은 함께 관리한다.

```text
grafana/dashboards/platform-app-overview.json
k8s/monitoring/11-platform-app-dashboard-configmap.yaml
```

Grafana UI에서 수정했다면 JSON을 내보내고 두 파일의 대시보드 내용이 일치하도록 갱신한 뒤 Pod를 다시 생성해 provisioning 결과를 확인한다.

## 9. k6로 결과 재현

정상 기준선은 성공률 SLI와 Error Budget을 확인하는 데 사용한다.

```bash
make load-test-baseline
```

지연 시나리오는 1초 초과 요청을 만들기 때문에 지연 SLI와 Error Budget을 낮춘다.

```bash
make load-test-latency
```

오류율 시나리오는 HTTP 500 요청을 만들기 때문에 성공률 SLI와 Error Budget을 낮춘다.

```bash
make load-test-error-rate
```

rolling 1h 창에는 이전 테스트의 요청도 함께 남는다. 시나리오가 끝난 직후 값이 즉시 100%로 복구되지 않는 것은 정상이며, 오래된 표본이 1시간 창에서 빠지면서 점차 회복한다.

## 10. 현재 범위와 다음 단계

현재 완료 범위는 다음과 같다.

```text
원본 Counter·Histogram
→ 기본 Recording Rule
→ rolling 1h SLI
→ SLO별 Error Budget
→ Grafana provisioning
→ k6 정상·지연·오류 시나리오로 변화 확인
```

다음 단계는 단순히 Error Budget이 음수가 된 뒤 알리는 것이 아니라, 서로 다른 시간 창의 소진 속도를 비교하는 burn-rate alert다.

```text
짧은 창의 빠른 소진
+ 긴 창의 지속적인 소진
→ multi-window burn-rate alert
```

이 방식은 일시적인 잡음을 줄이면서 사용자가 실제로 체감할 가능성이 큰 SLO 위반을 더 빠르게 탐지하는 데 목적이 있다.
