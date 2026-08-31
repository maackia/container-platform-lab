# Multi-window Burn Rate 경고

이 문서는 HTTP 성공률과 응답 지연 SLO의 Error Budget 소진 속도를 여러 시간 창에서 계산하고, 빠른 장애와 지속적인 품질 저하를 서로 다른 경고로 전달한 과정을 정리한다.

```text
Application Counter·Histogram
→ Burn Rate Recording Rule
→ 긴 창과 짧은 창을 함께 비교
→ PrometheusRule
→ Alertmanager
→ Discord FIRING / RESOLVED
```

## 1. Burn Rate의 의미

Burn Rate는 실제 나쁜 요청 비율을 SLO가 허용한 나쁜 요청 비율로 나눈 값이다.

```text
Burn Rate = 실제 나쁜 요청 비율 / 허용한 나쁜 요청 비율
```

현재 실습의 SLO와 허용량은 다음과 같다.

| 지표 | SLO | 나쁜 요청 | 허용 비율 |
|---|---:|---|---:|
| HTTP 성공률 | 99% | HTTP 5xx 응답 | 1% |
| HTTP 응답 지연 | 1초 이내 95% | 1초 초과 응답 | 5% |

Burn Rate 값은 다음처럼 해석한다.

```text
0x     → Error Budget을 사용하지 않음
1x     → SLO가 허용한 나쁜 요청 비율과 같은 속도로 Error Budget을 사용
6x     → 허용량보다 6배 빠르게 사용
14.4x  → 허용량보다 14.4배 빠르게 사용
20x    → 지연 SLO에서 관측 요청이 모두 1초를 초과한 상태
100x   → 성공률 SLO에서 관측 요청이 모두 5xx인 상태
```

Error Budget Remaining은 지금까지 얼마가 남았는지를 보여주고, Burn Rate는 지금 얼마나 빠르게 소진 중인지를 보여준다. 따라서 남은 양이 아직 있어도 소진 속도가 매우 빠르면 먼저 대응할 수 있다.

## 2. 리소스 구성

Burn Rate 계산과 경고를 두 파일로 분리한다.

```text
k8s/monitoring/18-platform-app-burn-rate-recording-rules.yaml
→ 성공률·지연 Burn Rate를 5m, 30m, 1h, 6h 창으로 계산

k8s/monitoring/19-platform-app-burn-rate-alerts.yaml
→ 긴 창과 짧은 창을 조합한 Fast Burn·Sustained Burn 경고
```

두 파일 모두 Prometheus의 `ruleSelector`에 선택되도록 `release: monitoring` 라벨을 가진다.

```yaml
metadata:
  labels:
    release: monitoring
```

## 3. 성공률 Burn Rate 계산

성공률 SLO의 나쁜 요청은 HTTP 5xx다. 5분 창의 계산을 단순화하면 다음과 같다.

```promql
(
  5분 동안 증가한 5xx 요청 수
  /
  5분 동안 증가한 전체 사용자 요청 수
)
/
0.01
```

실제 Recording Rule은 빈 시계열과 0으로 나누는 상황도 처리한다.

```promql
(
  (
    sum(increase(app_http_requests_total{
      namespace="platform-lab",
      job="app",
      route!~"/health|/metrics",
      status_code=~"5.."
    }[5m]))
    or vector(0)
  )
  /
  clamp_min(
    (
      sum(increase(app_http_requests_total{
        namespace="platform-lab",
        job="app",
        route!~"/health|/metrics"
      }[5m]))
      or vector(0)
    ),
    1
  )
)
/
0.01
and on()
(
  (
    sum(increase(app_http_requests_total{
      namespace="platform-lab",
      job="app",
      route!~"/health|/metrics"
    }[5m]))
    or vector(0)
  ) > 0
)
```

각 연산의 역할은 다음과 같다.

| 표현 | 역할 |
|---|---|
| `increase(...[5m])` | Counter가 최근 5분 동안 얼마나 증가했는지 계산 |
| `sum(...)` | Pod와 상태 코드 등 여러 시계열을 하나의 서비스 값으로 합산 |
| `route!~"/health|/metrics"` | 사용자 트래픽이 아닌 내부 점검 요청 제외 |
| `status_code=~"5.."` | 500~599 응답만 선택 |
| `or vector(0)` | 왼쪽 시계열이 없으면 계산에 사용할 0 제공 |
| `clamp_min(..., 1)` | 분모를 최소 1로 제한해 0으로 나누는 계산 방지 |
| `/ 0.01` | 실제 5xx 비율을 성공률 SLO의 허용 실패율 1%로 나눔 |
| `and on() ... > 0` | 실제 사용자 요청이 있을 때만 결과 시계열 유지 |

`increase()`는 5분 동안 매 순간 값을 계속 더하는 명령이 아니다. 계속 증가하는 Counter의 시작과 끝을 이용해 해당 범위에서 발생한 요청 수를 계산하며, Counter가 재시작으로 초기화되는 상황도 보정한다.

## 4. 지연 Burn Rate 계산

지연 SLO의 나쁜 요청은 1초를 초과한 응답이다. Histogram의 전체 요청 수에서 `le="1"` bucket을 빼면 1초 초과 요청 수를 얻을 수 있다.

```text
1초 초과 요청 수
= 전체 요청 수 - 1초 이하 요청 수
```

Burn Rate 계산은 다음 구조다.

```promql
(
  (
    전체 요청 수
    - 1초 이하 요청 수
  )
  /
  전체 요청 수
)
/
0.05
```

지연 SLO는 1초 이내 응답 95%를 목표로 하므로 허용 지연 비율은 `0.05`다. 모든 요청이 1초를 초과하면 실제 나쁜 요청 비율은 100%가 되고, Burn Rate는 `1 / 0.05 = 20x`가 된다.

## 5. Recording Rule 목록

같은 계산을 시간 창별로 반복 저장한다.

| Recording Rule | 창 | 용도 |
|---|---:|---|
| `platform_app:slo_http_success_burn_rate:5m` | 5분 | 성공률의 최근 급격한 변화 |
| `platform_app:slo_http_success_burn_rate:30m` | 30분 | 성공률의 단기 지속 여부 |
| `platform_app:slo_http_success_burn_rate:1h` | 1시간 | 성공률 Fast Burn의 긴 창 |
| `platform_app:slo_http_success_burn_rate:6h` | 6시간 | 성공률 Sustained Burn의 긴 창 |
| `platform_app:slo_http_latency_burn_rate:5m` | 5분 | 지연의 최근 급격한 변화 |
| `platform_app:slo_http_latency_burn_rate:30m` | 30분 | 지연의 단기 지속 여부 |
| `platform_app:slo_http_latency_burn_rate:1h` | 1시간 | 지연 Fast Burn의 긴 창 |
| `platform_app:slo_http_latency_burn_rate:6h` | 6시간 | 지연 Sustained Burn의 긴 창 |

Recording Rule의 `labels`에는 대시보드와 경고 조합에 사용할 정보를 명시한다.

```yaml
labels:
  namespace: platform-lab
  service: platform-app
  indicator: http-success
  objective: "0.99"
  window: 5m
```

## 6. Multi-window 경고

하나의 짧은 창만 보면 순간적인 요청 몇 건에도 민감하고, 하나의 긴 창만 보면 실제 장애를 늦게 발견할 수 있다. 이 실습은 긴 창과 짧은 창이 동시에 임계값을 넘을 때만 경고한다.

```text
긴 창 초과
AND
짧은 창 초과
→ 경고 조건 성립
```

| 구분 | 긴 창 | 짧은 창 | 임계값 | `for` | 심각도 |
|---|---:|---:|---:|---:|---|
| Fast Burn | 1시간 | 5분 | 14.4x | 1분 | critical |
| Sustained Burn | 6시간 | 30분 | 6x | 1분 | warning |

성공률과 지연에 각각 같은 창 조합을 적용해 총 네 개 경고를 만든다.

```text
PlatformAppHttpSuccessFastBurn
PlatformAppHttpSuccessSustainedBurn
PlatformAppHttpLatencyFastBurn
PlatformAppHttpLatencySustainedBurn
```

두 시계열은 공통 라벨로 결합한다.

```promql
and on(namespace, service, indicator, objective)
```

`window` 라벨은 긴 창과 짧은 창에서 값이 다르므로 결합 조건에 넣지 않는다.

## 7. 적용과 확인

정적 검사와 현재 클러스터 기준 검증을 먼저 실행한다.

```bash
kubeconform -strict -summary -ignore-missing-schemas k8s

kubectl apply --dry-run=server \
  -f k8s/monitoring/18-platform-app-burn-rate-recording-rules.yaml

kubectl apply --dry-run=server \
  -f k8s/monitoring/19-platform-app-burn-rate-alerts.yaml
```

검증 후 두 리소스를 적용한다.

```bash
kubectl apply \
  -f k8s/monitoring/18-platform-app-burn-rate-recording-rules.yaml

kubectl apply \
  -f k8s/monitoring/19-platform-app-burn-rate-alerts.yaml
```

Prometheus **Status → Rule health**에서 다음 그룹이 `OK`인지 확인한다.

```text
platform-app.burn-rate-recording-rules
platform-app.burn-rate-alerts
```

전체 시계열은 이름 정규식으로 조회할 수 있다.

```promql
{__name__=~"platform_app:slo_http_success_burn_rate:.*"}
```

```promql
{__name__=~"platform_app:slo_http_latency_burn_rate:.*"}
```

## 8. Grafana 대시보드

`Platform App Overview`의 `SLO Burn Rate (multi-window)` row는 성공률과 지연 Burn Rate를 시간 창별로 표시한다.

```text
HTTP Success Burn Rate
├→ 1h
├→ 30m
├→ 5m
└→ 6h

HTTP Latency Burn Rate
├→ 1h
├→ 30m
├→ 5m
└→ 6h
```

두 패널에는 `6x`와 `14.4x` 임계선을 표시한다. 그래프 축의 최대값은 고정하지 않고 `auto`를 사용해 20x, 100x 같은 실제 값을 잘라내지 않는다.

대시보드의 source of truth와 provisioning ConfigMap은 함께 갱신한다.

```text
grafana/dashboards/platform-app-overview.json
k8s/monitoring/11-platform-app-dashboard-configmap.yaml
```

## 9. k6 검증

### 정상 상태 관찰

baseline은 정상 트래픽에서 성공률과 지연 Burn Rate가 0x에 가까운지 관찰하는 별도 실험이다.

```bash
make load-test-baseline
```

baseline이 만든 정상 요청은 1시간 Recording Rule 창에 남는다. 따라서 Fast Burn 재현이 목적이라면 baseline 직후 latency를 연속해서 실행하지 않는다. 정상 요청이 섞이면 나쁜 요청 비율이 희석되어 1시간 Burn Rate가 `14.4x`를 넘지 못할 수 있다.

### Fast Burn 검증

Fast Burn 시나리오는 이전 사용자 요청이 1시간 창에서 빠진 상태에서 각각 독립적으로 실행한다. latency를 먼저 실행하거나, baseline 실행 후 최소 1시간이 지나 정상 요청이 창에서 제외된 것을 확인한다.

테스트 전에 최근 1시간 사용자 요청 수를 조회한다.

```promql
sum(increase(app_http_requests_total{
  namespace="platform-lab",
  job="app",
  route!~"/health|/metrics"
}[1h]))
```

결과가 0이거나 시계열이 없으면 latency 시나리오를 실행한다.

```bash
make load-test-latency
```

관측 창의 사용자 요청이 모두 `/slow`이고 각 응답이 1초를 초과하면 지연 Burn Rate는 약 20x가 된다. 1시간과 5분 창이 모두 14.4x를 넘고 1분 동안 유지되면 `PlatformAppHttpLatencyFastBurn`이 Firing된다.

오류율 Fast Burn도 다른 시나리오의 요청이 1시간 창에서 빠진 상태에서 독립적으로 실행한다. 오류율 시나리오는 HTTP 500 응답을 지속해서 발생시킨다.

```bash
make load-test-error-rate
```

관측 창의 사용자 요청이 모두 5xx라면 성공률 Burn Rate는 최대 100x가 된다.

대표 검증에서는 다음 흐름을 확인했다.

```text
k6 latency 또는 error-rate 실행
→ Burn Rate 임계값 초과
→ Prometheus Pending
→ 1분 유지 후 Firing
→ Discord FIRING 수신
→ 테스트 종료와 관측 창 경과
→ Discord RESOLVED 수신
```

기존 `PlatformAppHighP95Latency` 또는 `PlatformAppHighErrorRate` 경고와 Burn Rate 경고는 목적이 다르므로 함께 유지한다.

```text
기존 임계값 경고
→ 현재 증상이 기준을 넘었는지 알림

Burn Rate 경고
→ SLO의 허용량을 얼마나 빠르게 소진하는지 알림
```

같은 지연 상황에서 두 알림이 각각 도착하는 것은 현재 정책상 정상이다.

## 10. 결과가 없을 때

Burn Rate Recording Rule의 마지막 `and on() ... > 0` 조건 때문에 해당 시간 창에 사용자 요청이 없으면 결과가 사라진다. 먼저 원본 메트릭과 요청 수를 확인한다.

```promql
app_http_requests_total{namespace="platform-lab", job="app"}
```

```promql
sum(increase(app_http_requests_total{
  namespace="platform-lab",
  job="app",
  route!~"/health|/metrics"
}[5m]))
```

부하 테스트를 실행했는데도 Prometheus와 Grafana의 모든 최신 값이 함께 사라졌다면 브라우저와 VM의 시간 차이도 확인한다. VM 시간 드리프트 진단은 [VM 시간 동기화와 모니터링 복구](./15-vm-time-sync-and-monitoring-recovery.md)를 따른다.

## 11. 현재 범위와 다음 단계

현재 완료한 범위는 다음과 같다.

```text
성공률·지연 SLO 정의
→ rolling 1h Error Budget
→ 5m·30m·1h·6h Burn Rate Recording Rule
→ Fast Burn·Sustained Burn 경고
→ Grafana multi-window 패널
→ Discord FIRING·RESOLVED 확인
```

Sustained Burn은 6시간 창을 사용하므로 짧은 수동 실습에서 즉시 재현하기 어렵다. 현재는 규칙 로딩과 시계열 계산을 확인했고, 장시간 회귀 검증은 후속 자동화 범위로 남긴다.

다음 단계는 k6 실행, Prometheus 상태 조회와 알림 결과 확인을 하나의 반복 가능한 회귀 테스트로 연결하는 것이다.
