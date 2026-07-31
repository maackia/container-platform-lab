# Kubernetes 모니터링 스택

이 문서는 단일 노드 K3s 환경에 `kube-prometheus-stack`을 설치하고, `platform-lab` 애플리케이션의 메트릭을 Prometheus로 수집해 Grafana 대시보드에 표시한 과정을 정리한다.

구성 범위는 다음과 같다.

```text
Node.js Pod /metrics
→ app Service
→ ServiceMonitor
→ Prometheus Operator
→ Prometheus
→ Grafana
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
```

chart 설치로 `monitoring.coreos.com` CRD와 `monitoring` namespace가 준비된 뒤 애플리케이션 모니터링 리소스를 적용한다.

```bash
kubectl apply -f k8s/monitoring/
```

이 순서를 지키면 새 K3s 클러스터에서도 ServiceMonitor의 API를 찾지 못하거나 Grafana Dashboard ConfigMap의 namespace가 없어서 배포가 중단되는 일을 피할 수 있다.

## 5. Prometheus Operator와 ServiceMonitor

Prometheus Operator는 `Prometheus`, `ServiceMonitor`, `PrometheusRule` 같은 CRD를 Kubernetes API에 추가하고, 해당 리소스를 실제 Prometheus 설정으로 변환한다.

일반 Prometheus 설정 파일에 target을 직접 추가하는 대신 다음 ServiceMonitor를 선언했다.

```text
k8s/monitoring/10-app-servicemonitor.yaml
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

상태를 확인한다.

```bash
kubectl get servicemonitor app -n platform-lab
kubectl get service app -n platform-lab --show-labels
kubectl get endpointslice \
  -n platform-lab \
  -l kubernetes.io/service-name=app
```

## 6. Prometheus 접속과 쿼리

로컬에서 Prometheus에 접속하려면 port-forward를 실행한다.

```bash
kubectl port-forward \
  -n monitoring \
  service/monitoring-kube-prometheus-prometheus \
  9090:9090
```

다른 터미널에서 준비 상태를 확인한다.

```bash
curl -fsS http://localhost:9090/-/ready
```

Prometheus의 Target health에서 다음 scrape pool이 `2/2 UP`이면 애플리케이션 replica 두 개를 모두 수집하는 상태다.

```text
serviceMonitor/platform-lab/app/0
```

기본 확인 쿼리:

```promql
up{namespace="platform-lab", job="app"}
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

## 7. Grafana 대시보드

Grafana 접속용 port-forward를 실행한다.

```bash
kubectl port-forward \
  -n monitoring \
  service/monitoring-grafana \
  3001:80
```

관리자 비밀번호는 Secret에서 확인한다.

```bash
kubectl get secret monitoring-grafana \
  -n monitoring \
  -o jsonpath='{.data.admin-password}' \
  | base64 --decode
echo
```

대시보드 이름은 `Platform App Overview`이며 다음 항목을 표시한다.

| 패널 | 의미 |
|---|---|
| Running App Targets | Prometheus가 수집 중인 앱 target 수 |
| Application Request Rate | 애플리케이션 전체 HTTP 요청률 |
| Requests by Route | `/`, `/health`, `/metrics` 경로별 요청률 |
| CPU Usage by Pod | 앱 Pod별 CPU 사용량 |
| Memory Usage by Pod | 앱 Pod별 메모리 사용량 |

`Running App Targets`는 replica 두 개를 기준으로 `0=빨간색`, `1=노란색`, `2 이상=초록색`으로 표시한다. 전체 장애와 일부 장애가 정상 상태처럼 보이지 않도록 target 수에 맞춰 임계값을 설정한다.

원본 대시보드 리소스는 다음 파일에 보관한다.

```text
grafana/dashboards/platform-app-overview.json
```

## 8. 대시보드 자동 provisioning

Grafana UI에서 만든 대시보드를 Kubernetes ConfigMap으로 감싸고, Grafana sidecar가 자동으로 읽도록 구성했다.

```text
k8s/monitoring/11-platform-app-dashboard-configmap.yaml
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

## 9. Mac에서 SSH 터널로 접속

Prometheus와 Grafana port-forward가 Ubuntu VM의 loopback 주소에서 실행 중이라면 Mac에서 SSH local forwarding으로 연결할 수 있다.

```bash
ssh -p 2222 \
  -L 9090:127.0.0.1:9090 \
  -L 3001:127.0.0.1:3001 \
  micah@localhost
```

`-L`은 Mac의 로컬 포트를 SSH 서버가 실행 중인 Ubuntu VM의 주소와 포트로 전달한다.

```text
Mac localhost:3001
→ SSH tunnel
→ Ubuntu 127.0.0.1:3001
→ kubectl port-forward
→ Grafana Service
```

## 10. 정적 검증과 CI

CI는 도구와 chart 버전을 고정한다.

```text
HELM_VERSION: v4.2.3
KUBECONFORM_VERSION: 0.8.0
KUBE_PROMETHEUS_STACK_VERSION: 87.19.0
```

검증 순서는 다음과 같다.

```text
Grafana Dashboard v2 JSON 확인
→ 기본·모니터링 매니페스트 Kubeconform 검사
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
```

두 번째 명령은 `kube-prometheus-stack` 설치 후 실행해야 ServiceMonitor CRD와 `monitoring` namespace를 기준으로 검사할 수 있다.

두 검사는 서로 대체 관계가 아니다.

```text
Kubeconform
→ 빠르고 재현 가능한 정적 스키마 검사

kubectl --dry-run=server
→ 현재 클러스터의 CRD와 API 기준 검사
```

## 11. 주요 문제 해결

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

현재 사용자 정의 메트릭 이름은 `http_`가 아니라 `app_`으로 시작한다.

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

### Kubeconform의 missing kind 오류

렌더링 파일 첫 부분에 `Pulled:` 또는 `Digest:` 같은 Helm 메시지가 섞이면 Kubernetes 문서가 아닌 텍스트를 파싱하면서 `missing 'kind' key`가 발생할 수 있다.

CI에서는 chart를 먼저 로컬 파일로 pull하고, 해당 archive를 `helm template`에 넘겨 표준 출력에는 YAML만 저장한다.

```text
helm pull OCI chart
→ local .tgz
→ helm template local .tgz > rendered.yaml
```

## 12. 현재 완료 범위

```text
kube-prometheus-stack 설치
→ K3s 환경별 values 적용
→ Prometheus Operator와 CRD 구성
→ ServiceMonitor 기반 앱 메트릭 수집
→ 앱 replica 2개 target 확인
→ PromQL 쿼리 검증
→ Grafana 대시보드 구성
→ ConfigMap 기반 대시보드 provisioning
→ Helm 및 Kubernetes 리소스 CI 검증
```

다음 확장 단계에서는 경고 규칙과 Alertmanager, 또는 실제 부하를 발생시킨 상태에서 대시보드와 알림을 검증하는 과정을 다룰 수 있다.
