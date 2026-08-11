# Next.js 블로그 K3s 배포와 모니터링

이 문서는 별도 `maackia/blog` 저장소에서 게시한 Next.js 이미지를 기존 K3s 클러스터에 배포하고, Prometheus와 Grafana에 연결한 과정을 정리한다.

기존 `platform-lab` 데모 앱은 RED 메트릭·PostgreSQL·경고 실습용으로 유지하고, 블로그는 `blog` namespace에 별도 서비스로 배포한다.

## 1. 구성

```text
maackia/blog main push
→ GitHub Actions
→ ghcr.io/maackia/blog:latest
→ K3s blog Deployment
→ blog Service
→ Traefik Ingress
→ http://blog.platform.local:8081

Blog Pod /metrics
→ ServiceMonitor
→ Prometheus
→ Blog Overview Grafana Dashboard
```

블로그 이미지는 Next.js standalone build와 게시글 MDX를 포함한다. 따라서 글이나 디자인을 변경하면 새 이미지를 게시하고 Pod를 교체해야 한다.

## 2. 매니페스트 구조와 적용 순서

```text
k8s/blog/
├── 00-namespace.yaml
├── 01-blog-deployment.yaml
├── 02-blog-service.yaml
├── 03-blog-ingress.yaml
├── 04-blog-servicemonitor.yaml
└── 05-blog-dashboard-configmap.yaml
```

`00`∼`03`은 기본 K3s 리소스다. `04`는 Prometheus Operator의 ServiceMonitor CRD에, `05`는 Helm chart가 생성한 `monitoring` namespace와 Grafana sidecar에 의존한다.

새 클러스터에서는 먼저 기본 리소스만 적용한다.

```bash
kubectl apply -f k8s/blog/00-namespace.yaml
kubectl apply -f k8s/blog/01-blog-deployment.yaml
kubectl apply -f k8s/blog/02-blog-service.yaml
kubectl apply -f k8s/blog/03-blog-ingress.yaml
```

`kube-prometheus-stack`을 설치한 뒤 모니터링 리소스를 적용한다.

```bash
kubectl apply -f k8s/blog/04-blog-servicemonitor.yaml
kubectl apply -f k8s/blog/05-blog-dashboard-configmap.yaml
```

`kubectl apply -f k8s/`는 하위 디렉터리를 재귀 적용하지 않으므로 `k8s/blog/`을 자동으로 배포하지 않는다. 또한 모니터링 chart 설치 전에 `k8s/blog/` 전체를 적용하면 ServiceMonitor CRD나 `monitoring` namespace를 찾지 못해 중단될 수 있다.

## 3. Deployment와 health probe

블로그는 `linux/amd64`와 `linux/arm64`를 지원하는 GHCR 이미지를 Pod 두 개로 실행한다.

```text
Image: ghcr.io/maackia/blog:latest
Replicas: 2
Container port: 3000
Startup probe: /health/live
Readiness probe: /health/ready
Liveness probe: /health/live
```

startup probe는 Next.js 프로세스의 초기 기동을 기다린다. readiness probe가 성공한 Pod만 Service endpoint에 포함되고, liveness probe가 계속 실패하면 kubelet이 컨테이너를 재시작한다.

배포 상태를 확인한다.

```bash
kubectl rollout status deployment/blog -n blog --timeout=5m
kubectl get pods -n blog -o wide
kubectl get service blog -n blog
kubectl get endpointslice \
  -n blog \
  -l kubernetes.io/service-name=blog
```

Pod 두 개가 `1/1 Running`이고 EndpointSlice에 두 Pod IP가 모두 표시되면 Service가 준비된 상태다.

## 4. Traefik Ingress

`blog.platform.local`은 기존 UTM 호스트 `8081` → Ubuntu 게스트 `80` 포트 포워딩을 공유한다. 서비스별로 UTM 포트를 추가하지 않고 HTTP `Host` 헤더로 Traefik이 백엔드를 선택한다.

Mac의 `/etc/hosts`에 다음 항목을 추가한다.

```text
127.0.0.1 blog.platform.local
```

접속과 health endpoint를 확인한다.

```bash
curl --noproxy '*' -I \
  http://blog.platform.local:8081/

curl --noproxy '*' -fsS \
  http://blog.platform.local:8081/health/live

curl --noproxy '*' -fsS \
  http://blog.platform.local:8081/health/ready
```

## 5. ServiceMonitor와 Prometheus

ServiceMonitor는 `app=blog` 라벨을 가진 Service의 `http` 포트에서 `/metrics`를 15초마다 수집한다.

```text
ServiceMonitor selector: app=blog
→ blog Service label: app=blog
→ Service port name: http
→ Blog Pod:3000/metrics
```

상태를 확인한다.

```bash
kubectl get servicemonitor blog -n blog
kubectl get service blog -n blog --show-labels
```

Prometheus Target health에서 다음 scrape pool이 `2/2 UP`이어야 한다.

```text
serviceMonitor/blog/blog/0
```

기본 확인 PromQL:

```promql
up{namespace="blog"}
```

```promql
blog_published_posts{namespace="blog"}
```

```promql
blog_metrics_scrapes_total{namespace="blog"}
```

Pod는 각자 같은 게시글 수를 노출하므로 실제 게시글 수는 합계가 아닌 최댓값으로 확인한다.

```promql
max(blog_published_posts{namespace="blog"})
```

## 6. Blog Overview 대시보드

대시보드의 source of truth와 Kubernetes provisioning 리소스를 함께 관리한다.

```text
grafana/dashboards/blog-overview.json
k8s/blog/05-blog-dashboard-configmap.yaml
```

`grafana_dashboard=1` 라벨을 가진 ConfigMap을 Grafana sidecar가 감지해 대시보드를 자동으로 등록한다.

`Blog Overview`는 다음 항목을 표시한다.

| 패널 | 의미 |
|---|---|
| Running Blog Targets | Prometheus가 수집 중인 블로그 Pod 수 |
| Published Posts | 이미지에 포함된 게시글 수 |
| CPU Usage by Pod | Pod별 CPU 사용량 |
| Memory Usage by Pod | Pod별 working set 메모리 |
| Node.js Event Loop Lag p99 | Pod별 event loop 지연 |
| Container Restarts | Pod별 컨테이너 재시작 횟수 |

JSON을 수정하면 ConfigMap을 다시 생성해 두 파일의 내용을 동기화한다.

```bash
jq empty grafana/dashboards/blog-overview.json

kubectl create configmap blog-grafana-dashboard \
  --namespace monitoring \
  --from-file=blog-overview.json=grafana/dashboards/blog-overview.json \
  --dry-run=client \
  -o yaml \
  > /tmp/blog-dashboard.yaml

kubectl label --local \
  -f /tmp/blog-dashboard.yaml \
  grafana_dashboard=1 \
  -o yaml \
  > k8s/blog/05-blog-dashboard-configmap.yaml
```

## 7. `latest` 이미지 갱신

현재 실습은 `latest`와 `imagePullPolicy: Always`를 사용한다. `Always`는 Pod가 생성될 때 레지스트리의 이미지를 확인하지만, 실행 중인 Pod를 자동으로 교체하지는 않는다.

`maackia/blog` main 변경의 GitHub Actions 이미지 게시가 완료된 뒤 Deployment를 재시작한다.

```bash
kubectl rollout restart deployment/blog -n blog
kubectl rollout status deployment/blog -n blog --timeout=5m
```

실제 이미지 digest를 확인한다.

```bash
kubectl get pods -n blog -l app=blog \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}{end}'
```

`latest`는 간단하지만 같은 태그가 시점에 따라 다른 이미지를 가리킨다. 실제 운영으로 확장할 때는 불변 SHA·SemVer 태그와 Argo CD 또는 Flux 기반 GitOps 배포를 검토한다.

## 8. 검증

Kubeconform은 표준 Kubernetes 리소스를 검사하고, 기본 스키마 저장소에 없는 ServiceMonitor는 건너뛸 수 있다.

```bash
docker run --rm \
  -v "$PWD:/work:ro" \
  -w /work \
  ghcr.io/yannh/kubeconform:v0.8.0 \
  -strict -summary -ignore-missing-schemas \
  k8s/blog/*.yaml
```

실제 CRD와 API 기준 검증은 모니터링 chart 설치 후 서버 측 dry-run으로 보완한다.

```bash
kubectl apply --dry-run=server -f k8s/blog/01-blog-deployment.yaml
kubectl apply --dry-run=server -f k8s/blog/02-blog-service.yaml
kubectl apply --dry-run=server -f k8s/blog/03-blog-ingress.yaml
kubectl apply --dry-run=server -f k8s/blog/04-blog-servicemonitor.yaml
kubectl apply --dry-run=server -f k8s/blog/05-blog-dashboard-configmap.yaml
```

완료 기준은 다음과 같다.

```text
Blog Pod 2개 Ready
→ Service EndpointSlice에 Pod 2개 등록
→ blog.platform.local Ingress 접속
→ Prometheus target 2/2 UP
→ Blog Overview 대시보드 provisioning
→ latest 이미지 rollout 갱신 검증
```
