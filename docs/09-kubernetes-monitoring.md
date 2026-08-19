# Kubernetes 모니터링과 알림

이 문서는 단일 노드 K3s 환경에 `kube-prometheus-stack`을 설치하고, `platform-lab` 애플리케이션과 `blog` 서비스의 메트릭을 수집·시각화하며 replica 장애와 HTTP 오류율·p95 응답 지연을 경고로 전달한 과정을 정리한다.

구성 범위는 다음과 같다.

```text
Node.js Pod /metrics
→ app Service
→ ServiceMonitor
→ Prometheus Operator
→ Prometheus
├→ Grafana
└→ PrometheusRule → Alertmanager → AlertmanagerConfig → Discord

Mac browser
→ UTM port forwarding
→ Traefik Ingress
→ Grafana / Prometheus / Alertmanager Service
```

## 1. 실습 환경과 버전

```text
Kubernetes: K3s 단일 노드
Helm: 4.2.3
kube-prometheus-stack chart: 87.19.0
Kubeconform: 0.8.0
Monitoring namespace: monitoring
Application namespace: platform-lab
```

버전은 Helm values와 CI가 같은 결과를 만들 수 있도록 명시적으로 고정한다. 버전을 올릴 때는 chart 릴리스 노트와 values 변경 사항을 확인한 뒤 별도의 변경으로 반영한다.

## 2. Helm과 kube-prometheus-stack

Helm은 여러 Kubernetes 리소스를 하나의 chart로 묶고, values 파일을 통해 환경별 설정을 주입하는 패키지 관리자다.

`kube-prometheus-stack` chart는 다음 구성요소를 함께 설치한다.

- Prometheus Operator
- Prometheus
- Grafana
- Alertmanager
- kube-state-metrics
- prometheus-node-exporter
- ServiceMonitor와 PrometheusRule 등 모니터링 CRD

설정 파일은 다음과 같다.

```text
helm/kube-prometheus-stack-values.yaml
```

chart 원본을 수정하지 않고 values 파일에 필요한 차이만 선언한다. 이 방식이면 chart 버전과 사용자 설정을 분리해서 관리할 수 있다.

## 3. K3s 환경에 맞춘 values

단일 노드 기본 K3s는 별도의 etcd, controller-manager, scheduler, kube-proxy Pod를 일반적인 kubeadm 클러스터와 같은 방식으로 노출하지 않는다. 존재하지 않는 target에 대한 경고를 줄이기 위해 관련 수집과 규칙을 비활성화했다.

```yaml
kubeEtcd:
  enabled: false

kubeControllerManager:
  enabled: false

kubeScheduler:
  enabled: false

kubeProxy:
  enabled: false
```

애플리케이션 경고를 전달할 수 있도록 Alertmanager 구성요소는 활성화한다.

```yaml
alertmanager:
  enabled: true

  alertmanagerSpec:
    alertmanagerConfigSelector:
      matchLabels:
        alertmanagerConfig: platform-discord
    alertmanagerConfigMatcherStrategy:
      type: None
```

`defaultRules.rules.alertmanager: false`는 Alertmanager 프로세스를 끄는 설정이 아니라 chart가 제공하는 Alertmanager 자체 상태 경고 규칙을 비활성화하는 설정이다. 사용자 정의 애플리케이션 규칙과 Alertmanager 실행 여부는 별도로 관리된다.

`alertmanagerConfigSelector`는 `alertmanagerConfig=platform-discord` 라벨이 있는 `AlertmanagerConfig`만 선택한다. 설정 리소스는 `monitoring` namespace에 있지만 `platform-lab` 경고를 처리해야 하므로 namespace matcher를 강제로 추가하지 않는 `None` 전략을 사용한다. 기본 receiver인 `discard`는 선택된 외부 경로가 없는 알림을 조용히 처리하고, 실제 Discord 전송은 별도의 `AlertmanagerConfig`가 담당한다.

Grafana와 Prometheus 데이터는 K3s의 `local-path` StorageClass를 사용해 PVC에 저장한다.

```text
Grafana PVC: 2Gi
Prometheus PVC: 5Gi
Prometheus retention: 24h
Prometheus retentionSize: 4GiB
```

다른 namespace의 ServiceMonitor를 검색할 수 있도록 selector 제한을 해제했다.

```yaml
prometheus:
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    serviceMonitorSelector: {}
    serviceMonitorNamespaceSelector: {}
```

리소스 요청과 제한도 함께 지정해 단일 노드 실습 환경에서 각 구성요소가 사용할 수 있는 범위를 명시한다.

## 4. 설치와 상태 확인

OCI registry에서 고정된 chart 버전을 설치한다.

```bash
helm upgrade --install monitoring \
  oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
  --version 87.19.0 \
  --namespace monitoring \
  --create-namespace \
  -f helm/kube-prometheus-stack-values.yaml \
  --wait \
  --timeout 15m
```

`upgrade --install`은 release가 없으면 설치하고, 이미 있으면 values 변경을 반영한다. `--wait`는 주요 리소스가 준비될 때까지 기다리며, `--timeout`은 최대 대기 시간을 제한한다.

release와 Pod 상태를 확인한다.

```bash
helm list -n monitoring
helm status monitoring -n monitoring
kubectl get pods -n monitoring
kubectl get pvc -n monitoring
kubectl get prometheus,alertmanager -n monitoring
```

chart 설치로 `monitoring.coreos.com` CRD와 `monitoring` namespace가 준비되면 Discord Webhook을 Kubernetes Secret으로 생성한다. 실제 URL은 셸 기록이나 Git 파일에 직접 적지 않는다.

```bash
read -rsp "Discord webhook URL: " DISCORD_WEBHOOK_URL
echo
printf '%s' "$DISCORD_WEBHOOK_URL" \
  | kubectl create secret generic alertmanager-discord-webhook \
      --namespace monitoring \
      --from-file=webhook-url=/dev/stdin \
      --dry-run=client \
      -o yaml \
  | kubectl apply -f -
unset DISCORD_WEBHOOK_URL
```

Secret이 준비된 뒤 애플리케이션 모니터링 리소스를 적용한다.

```bash
kubectl apply -f k8s/monitoring/
kubectl apply -f k8s/blog/04-blog-servicemonitor.yaml
kubectl apply -f k8s/blog/05-blog-dashboard-configmap.yaml
```

이 순서를 지키면 새 K3s 클러스터에서도 ServiceMonitor의 API를 찾지 못하거나 Grafana Dashboard ConfigMap의 namespace가 없어서 배포가 중단되는 일을 피할 수 있다.

## 5. Prometheus Operator와 ServiceMonitor

Prometheus Operator는 `Prometheus`, `ServiceMonitor`, `PrometheusRule` 같은 CRD를 Kubernetes API에 추가하고, 해당 리소스를 실제 Prometheus 설정으로 변환한다.

일반 Prometheus 설정 파일에 target을 직접 추가하는 대신 다음 ServiceMonitor를 선언했다.

```text
k8s/monitoring/10-app-servicemonitor.yaml
k8s/blog/04-blog-servicemonitor.yaml
```

주요 설정은 다음과 같다.

```yaml
spec:
  namespaceSelector:
    matchNames:
      - platform-lab
  selector:
    matchLabels:
      app: platform-app
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
```

연결 관계는 다음과 같다.

```text
ServiceMonitor selector: app=platform-app
→ app Service label: app=platform-app
→ Service port name: http
→ targetPort: app Pod 3000
→ metrics path: /metrics
```

ServiceMonitor의 selector는 Pod가 아니라 Service의 `metadata.labels`를 찾는다. Service가 선택된 뒤 Service selector와 EndpointSlice를 통해 실제 Pod 주소가 target으로 등록된다.

블로그도 같은 방식으로 `app=blog` Service를 선택하고 `/metrics`를 수집한다.

상태를 확인한다.

```bash
kubectl get servicemonitor app -n platform-lab
kubectl get servicemonitor blog -n blog
kubectl get service app -n platform-lab --show-labels
kubectl get service blog -n blog --show-labels
kubectl get endpointslice \
  -n platform-lab \
  -l kubernetes.io/service-name=app

kubectl get endpointslice \
  -n blog \
  -l kubernetes.io/service-name=blog
```

## 6. Prometheus 접속과 쿼리

Traefik Ingress와 UTM 포트 포워딩을 구성한 뒤 다음 주소로 접속한다.

```text
http://prometheus.platform.local:8081
```

준비 상태를 확인한다.

```bash
curl --noproxy '*' -fsS \
  http://prometheus.platform.local:8081/-/ready
```

Prometheus의 Target health에서 다음 두 scrape pool이 각각 `2/2 UP`이면 데모 앱과 블로그 replica를 모두 수집하는 상태다.

```text
serviceMonitor/platform-lab/app/0
serviceMonitor/blog/blog/0
```

기본 확인 쿼리:

```promql
up{namespace="platform-lab", job="app"}
```

블로그 target과 게시글 메트릭은 다음으로 확인한다.

```promql
up{namespace="blog"}
```

```promql
max(blog_published_posts{namespace="blog"})
```

```promql
app_http_requests_total{namespace="platform-lab", job="app"}
```

```promql
sum(rate(app_http_requests_total{namespace="platform-lab", job="app"}[1m]))
```

```promql
sum by (route) (
  rate(app_http_requests_total{namespace="platform-lab", job="app"}[1m])
)
```

애플리케이션 v0.2.0은 요청 수 Counter와 요청 시간 Histogram을 노출한다. 이를 이용해 Rate, Errors, Duration 세 신호를 함께 확인한다.

학습용 트래픽 생성:

```bash
for i in $(seq 1 10); do
  curl --noproxy '*' -s \
    http://app.platform.local:8081/ > /dev/null
  curl --noproxy '*' -s \
    http://app.platform.local:8081/slow > /dev/null
  curl --noproxy '*' -s \
    http://app.platform.local:8081/error > /dev/null
done
```

route·상태 코드별 요청률:

```promql
sum by (route, status_code) (
  rate(app_http_requests_total{
    namespace="platform-lab",
    job="app",
    route!~"/health|/metrics"
  }[5m])
)
```

5xx 오류율:

```promql
100 *
sum(
  rate(app_http_requests_total{
    namespace="platform-lab",
    job="app",
    status_code=~"5..",
    route!~"/health|/metrics"
  }[5m])
)
/
clamp_min(
  sum(
    rate(app_http_requests_total{
      namespace="platform-lab",
      job="app",
      route!~"/health|/metrics"
    }[5m])
  ),
  0.000001
)
```

route별 p95 응답시간:

```promql
histogram_quantile(
  0.95,
  sum by (le, route) (
    rate(app_http_request_duration_seconds_bucket{
      namespace="platform-lab",
      job="app",
      route!~"/health|/metrics"
    }[5m])
  )
)
```

현재 전체 p95 응답시간:

```promql
histogram_quantile(
  0.95,
  sum by (le) (
    rate(app_http_request_duration_seconds_bucket{
      namespace="platform-lab",
      job="app",
      route!~"/health|/metrics"
    }[5m])
  )
)
```

Prometheus Query UI에서는 고정 range selector인 `[5m]`을 사용한다. Grafana 대시보드에서는 패널의 시간 범위와 scrape 주기에 맞게 `$__rate_interval`로 바꿔 사용할 수 있다.

Histogram 기반 p95는 선택한 시간 범위의 표본으로 계산한 추정값이다. 요청이 없으면 그래프가 비어 있을 수 있으므로 `/`, `/slow`, `/error` 트래픽을 발생시킨 뒤 확인한다.

## 7. Grafana 대시보드

Grafana는 다음 주소로 접속한다.

```text
http://grafana.platform.local:8081
```

관리자 비밀번호는 Secret에서 확인한다.

```bash
kubectl get secret monitoring-grafana \
  -n monitoring \
  -o jsonpath='{.data.admin-password}' \
  | base64 --decode
echo
```

기본 애플리케이션 대시보드 이름은 `Platform App Overview`이며 다음 항목을 표시한다.

| 패널 | 의미 |
|---|---|
| Running App Targets | Prometheus가 수집 중인 앱 target 수 |
| Current p95 Response Time | 최근 요청의 전체 p95 응답시간 |
| Requests by Route | `/`, `/error`, `/slow` 등 경로별 요청률 |
| p95 Response Time by Route | 경로별 p95 응답시간 추이 |
| Application Request Rate | route·상태 코드별 HTTP 요청률 |
| Application Error Rate (%) | 전체 요청 중 5xx 응답 비율 |
| CPU Usage by Pod | 앱 Pod별 CPU 사용량 |
| Memory Usage by Pod | 앱 Pod별 메모리 사용량 |
| Node.js Event Loop Lag p99 | Node.js event loop 지연의 p99 |

`Running App Targets`는 replica 두 개를 기준으로 `0=빨간색`, `1=노란색`, `2 이상=초록색`으로 표시한다. 전체 장애와 일부 장애가 정상 상태처럼 보이지 않도록 target 수에 맞춰 임계값을 설정한다.

`Current p95 Response Time`은 `0.5초 이상=노란색`, `1초 이상=빨간색`으로 표시한다. `/slow` 요청을 발생시키면 느린 응답이 p95와 route별 그래프에 반영되는 과정을 확인할 수 있다.

원본 대시보드 리소스는 다음 파일에 보관한다.

```text
grafana/dashboards/platform-app-overview.json
grafana/dashboards/blog-overview.json
```

`Blog Overview`는 블로그 target 수, 게시글 수, Pod별 CPU·메모리, Node.js event loop 지연과 재시작 횟수를 표시한다. 블로그 배포와 대시보드 재생성 절차는 [Next.js 블로그 K3s 배포와 모니터링](./10-blog-k3s.md)에 정리한다.

## 8. 대시보드 자동 provisioning

Grafana UI에서 만든 대시보드를 Kubernetes ConfigMap으로 감싸고, Grafana sidecar가 자동으로 읽도록 구성했다.

```text
k8s/monitoring/11-platform-app-dashboard-configmap.yaml
k8s/blog/05-blog-dashboard-configmap.yaml
```

ConfigMap 바깥쪽 `metadata.labels`에 다음 라벨이 있어야 sidecar의 검색 대상이 된다.

```yaml
metadata:
  labels:
    grafana_dashboard: "1"
```

`data`에는 Grafana에서 내보낸 Dashboard v2 JSON을 문자열로 저장한다.

```yaml
data:
  platform-app-overview.json: |-
    {
      "apiVersion": "dashboard.grafana.app/v2",
      "kind": "Dashboard"
    }
```

적용 후 ConfigMap과 sidecar 로그를 확인한다.

```bash
kubectl apply -f k8s/monitoring/11-platform-app-dashboard-configmap.yaml
kubectl get configmap platform-app-grafana-dashboard -n monitoring
kubectl logs -n monitoring \
  deployment/monitoring-grafana \
  -c grafana-sc-dashboard \
  --tail=100
```

대시보드를 UI에서만 저장하면 Grafana PVC에는 남지만 Git으로 변경 이력을 관리할 수 없다. JSON과 ConfigMap을 저장소에 함께 보관하면 새 환경에서도 같은 대시보드를 재현할 수 있다.

대시보드의 source of truth는 다음 JSON이다.

```text
grafana/dashboards/platform-app-overview.json
```

Grafana UI에서 내보낸 JSON을 사용하거나 이 파일을 직접 수정한 뒤 ConfigMap을 다시 생성한다.

```bash
jq empty grafana/dashboards/platform-app-overview.json

kubectl create configmap platform-app-grafana-dashboard \
  --namespace monitoring \
  --from-file=platform-app-overview.json=grafana/dashboards/platform-app-overview.json \
  --dry-run=client \
  -o yaml \
  > /tmp/platform-app-dashboard.yaml

kubectl label --local \
  -f /tmp/platform-app-dashboard.yaml \
  grafana_dashboard=1 \
  -o yaml \
  > k8s/monitoring/11-platform-app-dashboard-configmap.yaml

kubectl apply \
  -f k8s/monitoring/11-platform-app-dashboard-configmap.yaml
```

```text
Dashboard JSON 수정
→ ConfigMap 재생성
→ kubectl apply
→ Grafana sidecar 감지
→ 대시보드 자동 갱신
```

직접 수정과 UI 편집 모두 가능하지만, 최종 변경은 JSON과 ConfigMap에 반영해야 새 클러스터에서도 같은 대시보드를 재현할 수 있다.

## 9. PrometheusRule과 Alertmanager

애플리케이션 replica 상태를 감시하는 사용자 정의 규칙은 다음 파일에 선언한다.

```text
k8s/monitoring/12-platform-app-prometheusrule.yaml
```

Prometheus가 이 규칙을 선택할 수 있도록 Helm release와 같은 라벨을 사용한다.

```yaml
metadata:
  labels:
    release: monitoring
```

Prometheus 리소스의 `ruleSelector`가 `release=monitoring`을 요구하므로 라벨이 없거나 값이 다르면 `PrometheusRule`을 생성해도 실제 규칙 목록에 나타나지 않는다. `ruleNamespaceSelector: {}`는 `platform-lab`처럼 다른 namespace의 규칙도 검색하게 한다.

추가한 규칙은 다음 네 개다.

| 경고 | 조건 | 지속 시간 | 심각도 |
|---|---|---:|---|
| `PlatformAppReplicaDegraded` | 사용 가능한 app replica가 1개 | 1분 | warning |
| `PlatformAppDown` | 사용 가능한 app replica가 0개 | 1분 | critical |
| `PlatformAppHighErrorRate` | 최소 요청률을 충족하면서 HTTP 5xx 비율이 10% 초과 | 1분 | warning |
| `PlatformAppHighP95Latency` | 경로별 p95 응답시간이 1초 초과 | 1분 | warning |

오류율 규칙은 `/health`와 `/metrics`를 사용자 트래픽에서 제외하고, 전체 요청률이 초당 `0.05`보다 클 때만 평가한다. 트래픽이 거의 없는 환경에서 단일 실패 요청만으로 오류율이 100%가 되는 오탐을 줄이기 위한 조건이다.

p95 규칙은 Histogram bucket을 `le`와 `route` 기준으로 집계해 경로별 95번째 백분위 응답시간을 계산한다. 이 규칙도 내부 점검 경로를 제외하므로 실제 애플리케이션 경로의 지연을 대상으로 한다.

경고는 조건이 참이 되는 즉시 알림으로 전달되지 않는다.

```text
조건이 거짓 → Inactive
조건이 참 → Pending
1분 동안 계속 참 → Firing
replica 복구 → Resolved
```

규칙과 Alertmanager 상태를 확인한다.

```bash
kubectl get prometheusrule platform-app-alerts -n platform-lab
kubectl get prometheus,alertmanager -n monitoring
kubectl get pods -n monitoring \
  -l app.kubernetes.io/name=alertmanager
```

실습에서는 app replica를 단계적으로 줄여 경고 상태를 확인했다.

```bash
kubectl scale deployment/app -n platform-lab --replicas=1
kubectl rollout status deployment/app -n platform-lab

kubectl scale deployment/app -n platform-lab --replicas=0
kubectl rollout status deployment/app -n platform-lab
```

검증이 끝나면 반드시 원래 상태로 복구한다.

```bash
kubectl scale deployment/app -n platform-lab --replicas=2
kubectl rollout status deployment/app -n platform-lab
kubectl get pods -n platform-lab -l app=platform-app
```

### HTTP 오류율과 p95 응답 지연 검증

오류와 지연 조건을 동시에 유지하기 위해 `/error`와 `/slow` 요청을 약 2분 30초 동안 반복했다.

```bash
for i in {1..100}; do
  curl --noproxy '*' -s -o /dev/null \
    http://app.platform.local:8081/error

  curl --noproxy '*' -s -o /dev/null \
    http://app.platform.local:8081/slow
done
```

테스트 중 Prometheus에서 두 규칙이 다음 순서로 바뀌는 것을 확인했다.

```text
PlatformAppHighErrorRate
Inactive → Pending → Firing

PlatformAppHighP95Latency{route="/slow"}
Inactive → Pending → Firing
```

Alertmanager와 Discord에서 두 경고의 FIRING 알림을 확인하고, 요청을 중단한 뒤 최근 2분 범위에서 테스트 트래픽이 사라지면서 Resolved 상태와 Discord 복구 알림까지 확인했다.

최근 범위에 해당 경로의 요청이 없으면 `histogram_quantile` 결과가 `NaN`으로 보일 수 있다. 이는 규칙 로딩 실패가 아니라 계산할 최신 표본이 없다는 뜻이며, 과거 구간은 Grafana 범위 그래프에서 확인할 수 있다.

Discord 라우팅은 다음 파일에 선언한다.

```text
k8s/monitoring/14-platform-discord-alertmanagerconfig.yaml
```

현재 클러스터의 CRD가 제공하는 `monitoring.coreos.com/v1alpha1` API를 사용한다. `AlertmanagerConfig`는 `service=platform-app` 경고만 선택하며, Webhook URL은 같은 `monitoring` namespace의 `alertmanager-discord-webhook` Secret에서 읽는다.

```yaml
spec:
  route:
    receiver: discord-platform
    groupBy:
      - namespace
      - alertname
    groupWait: 10s
    groupInterval: 5m
    repeatInterval: 4h
    matchers:
      - name: service
        value: platform-app
        matchType: "="
  receivers:
    - name: discord-platform
      discordConfigs:
        - apiURL:
            name: alertmanager-discord-webhook
            key: webhook-url
          sendResolved: true
```

알림 경로는 다음과 같다.

```text
PrometheusRule Firing
→ Prometheus
→ Alertmanager
→ AlertmanagerConfig label·matcher 선택
→ Kubernetes Secret의 Webhook URL 사용
→ Discord FIRING 알림

replica 복구
→ Resolved
→ groupInterval 이후 Discord RESOLVED 알림
```

리소스와 조정 상태를 확인한다.

```bash
kubectl get secret alertmanager-discord-webhook -n monitoring
kubectl get alertmanagerconfig platform-discord -n monitoring
kubectl get alertmanager monitoring-kube-prometheus-alertmanager \
  -n monitoring \
  -o json \
  | jq '.status.conditions'
```

`sendResolved: true`여도 복구 알림은 즉시 전송되지 않을 수 있다. `groupInterval: 5m`은 기존 알림 그룹에서 새 경고나 복구가 생겼는지 확인하는 간격이므로, 실습에서 RESOLVED 메시지가 몇 분 뒤 도착하는 것은 정상이다.

### Silence와 Inhibition

Alertmanager는 같은 알림 피로를 줄이는 두 가지 억제 방식을 제공한다.

| 구분 | Silence | Inhibition |
|---|---|---|
| 목적 | 유지보수처럼 예상한 시간 동안 알림을 수동 억제 | 상위 장애가 발생했을 때 파생되는 하위 경고를 자동 억제 |
| 생성 위치 | Alertmanager UI 또는 API | Git으로 관리하는 `AlertmanagerConfig` |
| 조건 | 사용자가 지정한 matcher와 만료 시간 | source·target matcher와 `equal` 라벨 |
| 현재 실습 | `PlatformAppDown`을 정해진 시간 동안 Silence | critical `PlatformAppDown`이 활성화되면 같은 서비스의 warning 억제 |

Inhibition 정책은 다음 파일에 선언한다.

```text
k8s/monitoring/15-platform-alert-inhibition.yaml
```

```yaml
spec:
  inhibitRules:
    - sourceMatch:
        - name: alertname
          matchType: "="
          value: PlatformAppDown
        - name: severity
          matchType: "="
          value: critical
      targetMatch:
        - name: service
          matchType: "="
          value: platform-app
        - name: severity
          matchType: "="
          value: warning
      equal:
        - namespace
        - service
```

`sourceMatch`는 억제를 시작하는 상위 경고, `targetMatch`는 억제할 하위 경고를 선택한다. `equal`은 두 경고의 `namespace`와 `service` 라벨 값이 모두 같을 때만 정책을 적용해 다른 환경이나 서비스의 경고가 함께 숨겨지는 것을 막는다.

오류율 규칙의 `sum(...)`과 p95 규칙의 `sum by (le, route)`는 원본 시계열의 `namespace` 라벨을 집계 과정에서 제거한다. Inhibition의 `equal` 비교에 필요한 라벨을 항상 보존하도록 두 경고의 정적 라벨에 namespace를 명시한다.

```yaml
labels:
  namespace: platform-lab
  severity: warning
  service: platform-app
```

Inhibition은 경고 자체를 없애지 않고 전달만 억제한다.

```text
Prometheus
→ source와 target 모두 Firing

Alertmanager
→ source는 Active
→ target은 Inhibited

Discord
→ source 알림만 전송
```

실제 애플리케이션을 0 replica로 내리면 HTTP 표본이 더 이상 생성되지 않아 오류율이나 p95 경고가 먼저 사라질 수 있다. 그래서 정책 자체를 재현 가능하게 검증할 때는 `service=platform-app`, `severity=warning` 라벨을 가진 임시 `vector(1)` 규칙을 사용했다.

검증 순서는 다음과 같다.

```text
1. 임시 warning 경고를 Firing 상태로 만든다.
2. PlatformAppDown이 Firing될 때까지 기다린다.
3. Prometheus에서 두 경고가 모두 Firing인지 확인한다.
4. Alertmanager에서 warning이 Inhibited인지 확인한다.
5. Discord에는 critical 경고만 새로 도착하는지 확인한다.
6. 임시 규칙을 삭제하고 app replica를 2개로 복구한다.
```

target 경고가 source보다 먼저 Firing되면 source가 활성화되기 전까지 Discord 알림 한 건이 전송될 수 있다. Inhibition은 이미 전송된 메시지를 회수하지 않으며, source와 target이 동시에 활성화된 시점부터 이후 알림을 억제한다.

## 10. Traefik Ingress로 모니터링 서비스 접근

모니터링 서비스용 Ingress는 다음 파일에 선언한다.

```text
k8s/monitoring/13-monitoring-ingress.yaml
```

Ingress와 백엔드 Service는 같은 namespace에 있어야 하므로 이 리소스는 `monitoring` namespace에 생성한다. 외부 접근에는 chart가 만든 일반 ClusterIP Service를 사용하고, `prometheus-operated`와 `alertmanager-operated` 같은 내부 Headless Service는 사용하지 않는다.

라우팅 구성은 다음과 같다.

```text
grafana.platform.local
→ monitoring-grafana:80

prometheus.platform.local
→ monitoring-kube-prometheus-prometheus:9090

alertmanager.platform.local
→ monitoring-kube-prometheus-alertmanager:9093
```

Mac의 `/etc/hosts`에는 다음 항목을 추가한다.

```text
127.0.0.1 app.platform.local
127.0.0.1 grafana.platform.local
127.0.0.1 prometheus.platform.local
127.0.0.1 alertmanager.platform.local
```

UTM에서는 호스트 `8081`을 Ubuntu 게스트 `80`으로 한 번만 전달한다. 이후 Traefik이 HTTP `Host` 헤더를 보고 목적지를 결정한다.

```text
Mac browser :8081
→ UTM guest :80
→ Traefik
→ matching Kubernetes Service
```

접근 상태를 확인한다.

```bash
kubectl get ingress -A

curl --noproxy '*' -fsS \
  http://app.platform.local:8081/health

curl --noproxy '*' -fsS \
  http://grafana.platform.local:8081/api/health

curl --noproxy '*' -fsS \
  http://prometheus.platform.local:8081/-/ready

curl --noproxy '*' -fsS \
  http://alertmanager.platform.local:8081/-/ready
```

회사 VPN이나 HTTP 프록시가 로컬 도메인을 가로채는 환경에서는 `--noproxy '*'`로 직접 연결 여부를 확인한다.

## 11. port-forward와 SSH 터널

Ingress를 사용할 수 없는 임시 점검 상황에서는 `kubectl port-forward`로 특정 Service만 로컬에 노출할 수 있다.

```bash
kubectl port-forward -n monitoring \
  service/monitoring-kube-prometheus-prometheus \
  9090:9090

kubectl port-forward -n monitoring \
  service/monitoring-grafana \
  3001:80
```

port-forward가 Ubuntu VM의 loopback 주소에서 실행 중이라면 Mac에서 SSH local forwarding으로 연결한다.

```bash
ssh -p 2222 \
  -L 9090:127.0.0.1:9090 \
  -L 3001:127.0.0.1:3001 \
  micah@localhost
```

```text
Mac localhost:3001
→ SSH tunnel
→ Ubuntu 127.0.0.1:3001
→ kubectl port-forward
→ Grafana Service
```

Ingress는 여러 서비스를 지속적으로 접근하는 기본 경로이고, port-forward와 SSH 터널은 일회성 디버깅 경로로 구분한다.

## 12. 정적 검증과 CI

CI는 도구와 chart 버전을 고정한다.

```text
HELM_VERSION: v4.2.3
KUBECONFORM_VERSION: 0.8.0
KUBE_PROMETHEUS_STACK_VERSION: 87.19.0
```

검증 순서는 다음과 같다.

```text
Grafana Dashboard v2 JSON 확인
→ 기본·모니터링·블로그 매니페스트 Kubeconform 검사
→ Helm chart pull
→ helm lint
→ helm template
→ 렌더링된 리소스 Kubeconform 검사
```

`helm lint`는 chart와 values 구성을 검사하고, `helm template`은 API 서버에 적용하지 않은 채 최종 Kubernetes YAML을 렌더링한다. Kubeconform은 렌더링 결과의 스키마와 알 수 없는 필드를 검사한다.

Prometheus Operator CRD처럼 기본 Kubernetes 스키마 저장소에 없는 리소스는 `-ignore-missing-schemas`로 건너뛴다. 따라서 Kubeconform 결과의 `Skipped`는 곧 실패를 의미하지 않는다. 실제 클러스터의 CRD와 admission 설정은 서버 측 dry-run으로 추가 확인한다.

```bash
kubectl apply --dry-run=server -f k8s/
kubectl apply --dry-run=server -f k8s/monitoring/
kubectl apply --dry-run=server -f k8s/blog/04-blog-servicemonitor.yaml
kubectl apply --dry-run=server -f k8s/blog/05-blog-dashboard-configmap.yaml
```

후속 모니터링 명령은 `kube-prometheus-stack` 설치 후 실행해야 ServiceMonitor CRD와 `monitoring` namespace를 기준으로 검사할 수 있다.

두 검사는 서로 대체 관계가 아니다.

```text
Kubeconform
→ 빠르고 재현 가능한 정적 스키마 검사

kubectl --dry-run=server
→ 현재 클러스터의 CRD와 API 기준 검사
```

## 13. 주요 문제 해결

### OCI registry 인증서 오류

```text
x509: certificate signed by unknown authority
```

회사 VPN이나 TLS 검사 프록시를 사용하는 환경에서는 VM 또는 Helm이 GHCR 인증서 체인을 신뢰하지 못할 수 있다. VPN 연결 상태와 회사 CA 설치 여부를 먼저 확인한다. 인증서 검증을 비활성화하는 방식은 기본 해결책으로 사용하지 않는다.

### 리소스 이름 오타

```text
resources.requests[momery]
```

Kubernetes 표준 리소스 키는 `memory`다. API 서버의 strict validation이 오타를 알 수 없는 리소스 타입으로 판단하므로 values를 수정한 뒤 다시 `helm upgrade --install`한다.

### Prometheus에 scrape pool만 있고 target이 없는 경우

```text
0 / 0 up
No targets
```

ServiceMonitor는 발견됐지만 selector와 일치하는 Service가 없을 가능성이 크다.

```bash
kubectl get servicemonitor app -n platform-lab \
  -o jsonpath='{.spec.selector.matchLabels}'

kubectl get service app -n platform-lab \
  -o jsonpath='{.metadata.labels}'
```

두 라벨을 일치시킨 뒤 Service를 다시 적용한다.

### HTTP 메트릭 검색 결과가 비어 있는 경우

현재 사용자 정의 메트릭 이름은 `http_`가 아니라 `app_`으로 시작한다. 메트릭 이름은 완전히 일치해야 하며, 오류율 규칙에서 단수형 `app_http_request_total`을 사용하면 시계열을 찾지 못한다.

```text
app_http_requests_total
```

따라서 `__name__=~"http_.*"`는 일치하지 않는다. 정확한 이름을 사용하거나 다음처럼 검색한다.

```promql
{namespace="platform-lab", job="app", __name__=~".*http.*"}
```

### Prometheus 시간 불일치 경고

Mac은 Asia/Seoul, Ubuntu는 UTC로 표시돼도 절대 시간이 같고 NTP가 동기화돼 있으면 문제가 아니다.

```bash
timedatectl status
```

`System clock synchronized: yes`와 `NTP service: active`를 확인한다. timezone 표기보다 실제 시계가 어긋났는지가 중요하다.

### 애플리케이션 경고가 계속 Inactive인 경우

`Inactive`는 규칙 로딩 실패가 아니라 현재 표현식의 조건이 거짓이라는 뜻일 수 있다. 먼저 실제 replica 수와 규칙의 쿼리 결과를 확인한다.

```bash
kubectl get deployment app -n platform-lab
kubectl get prometheusrule platform-app-alerts -n platform-lab
```

정상 replica가 2개인 상태에서는 `== 1`과 `== 0` 조건이 모두 거짓이므로 두 규칙이 Inactive인 것이 정상이다. replica를 줄인 뒤에도 즉시 Firing되지 않는 이유는 `for: 1m` 동안 조건이 계속 참이어야 하기 때문이다.

### Alertmanager 화면에서 경고가 바로 보이지 않는 경우

Prometheus에서 규칙이 Firing이어도 Alertmanager 화면에서는 namespace별 그룹이 접힌 상태일 수 있다. `namespace="platform-lab"` 그룹을 펼치고 `active=true`, `silenced=false`, `inhibited=false` 필터를 확인한다.

Discord 알림이 도착하지 않으면 `AlertmanagerConfig` 라벨과 Helm의 `alertmanagerConfigSelector`가 같은지, 경고에 `service=platform-app` 라벨이 있는지, Secret의 이름과 key가 각각 `alertmanager-discord-webhook`, `webhook-url`인지 확인한다.

### Inhibition이 적용되지 않는 경우

Prometheus에서 source와 target 경고가 동시에 Firing인지 먼저 확인한다. 그다음 두 경고에 `equal`에서 요구하는 `namespace`와 `service` 라벨이 모두 존재하고 값도 같은지 확인한다.

```bash
kubectl get alertmanagerconfig platform-alert-inhibition \
  -n monitoring \
  -o yaml
```

Prometheus 집계 연산이 라벨을 제거할 수 있으므로 필요하면 `PrometheusRule`의 `labels`에 비교용 값을 명시한다. Alertmanager 화면에서 `Inhibited` 필터도 활성화해야 억제된 경고가 표시된다. source보다 먼저 전송된 target 메시지는 정책 적용 후에도 Discord에서 사라지지 않는다.

### AlertmanagerConfig API 버전을 찾지 못하는 경우

```text
no matches for kind "AlertmanagerConfig" in version "monitoring.coreos.com/v1beta1"
```

설치된 CRD가 제공하는 API 버전을 확인한다.

```bash
kubectl get crd alertmanagerconfigs.monitoring.coreos.com \
  -o jsonpath='{range .spec.versions[*]}{.name}{"\tserved="}{.served}{"\tstorage="}{.storage}{"\n"}{end}'
```

현재 환경은 `v1alpha1`을 제공하므로 매니페스트도 같은 버전을 사용한다. CRD를 임의로 교체하기보다 설치된 chart와 Operator가 제공하는 API에 맞추고 서버 측 dry-run으로 검증한다.

### Kubeconform의 missing kind 오류

렌더링 파일 첫 부분에 `Pulled:` 또는 `Digest:` 같은 Helm 메시지가 섞이면 Kubernetes 문서가 아닌 텍스트를 파싱하면서 `missing 'kind' key`가 발생할 수 있다.

CI에서는 chart를 먼저 로컬 파일로 pull하고, 해당 archive를 `helm template`에 넘겨 표준 출력에는 YAML만 저장한다.

```text
helm pull OCI chart
→ local .tgz
→ helm template local .tgz > rendered.yaml
```

## 14. 현재 완료 범위

```text
kube-prometheus-stack 설치
→ K3s 환경별 values 적용
→ Prometheus Operator와 CRD 구성
→ ServiceMonitor 기반 앱 메트릭 수집
→ 앱 replica 2개 target 확인
→ 블로그 replica 2개 target 및 게시글 메트릭 확인
→ 애플리케이션 v0.2.0 배포
→ RED 요청률·오류율·p95 쿼리 검증
→ Grafana RED·Pod 리소스 대시보드 구성
→ Blog Overview 대시보드 구성
→ ConfigMap 기반 대시보드 provisioning
→ PrometheusRule 기반 replica·HTTP 5xx 오류율·p95 응답 지연 경고
→ Alertmanager Pending·Firing·Resolved 검증
→ AlertmanagerConfig와 Secret 기반 Discord FIRING·RESOLVED 알림
→ Alertmanager Silence 기반 유지보수 알림 억제
→ critical source와 warning target의 namespace·service 기반 Inhibition
→ Traefik 호스트 기반 모니터링 Ingress
→ UTM 단일 HTTP 포트 포워딩
→ Helm 및 Kubernetes 리소스 CI 검증
```

다음 확장 단계에서는 알림 정책 테스트 자동화, 재현 가능한 부하 테스트, SLO와 recording rule을 다룰 수 있다.
