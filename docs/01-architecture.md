# 프로젝트 구조와 아키텍처

## 1. 목적

이 프로젝트는 단일 호스트 Docker Compose에서 시작해 CI/CD, 컨테이너 레지스트리, K3s 배포와 클러스터 모니터링까지 확장한 실습 저장소다.

두 가지 애플리케이션을 운영한다.

```text
container-platform-lab app
→ Node.js + PostgreSQL
→ 메트릭·장애·데이터 실습

maackia/blog
→ Next.js + MDX
→ 별도 GHCR 이미지를 K3s에 배포하는 실제 서비스 응용
```

기존 데모 앱을 교체하지 않고 블로그를 별도 namespace에 배포해 학습용 메트릭과 실제 서비스를 함께 관찰한다.

## 2. Docker Compose 구조

```text
Client
→ nginx:8080
→ Node.js app:3000
→ PostgreSQL:5432

Node.js /metrics
→ Prometheus
→ Grafana
```

### nginx

외부 요청을 받아 Node.js 앱으로 전달하는 reverse proxy다. Compose 환경에서 클라이언트는 `localhost:8080`으로 접속한다.

### Node.js app

요청 라우팅, PostgreSQL 방문 기록과 Prometheus 메트릭을 제공한다.

```text
/health  → 준비 상태
/        → visit row 삽입·조회
/metrics → Prometheus 메트릭
```

### PostgreSQL

`visits` 테이블에 방문 기록을 저장한다. Compose named volume과 K3s PVC로 컨테이너 생명주기와 데이터 생명주기를 분리한다.

Compose 시작 순서는 healthcheck를 기준으로 조정한다.

```text
db healthy
→ app start
→ app healthy
→ nginx start
```

## 3. CI/CD와 이미지 게시

```text
Pull Request
├→ Node.js·Compose 통합 테스트
└→ Kubernetes·Helm·Grafana 리소스 검증

main / Git tag
→ Buildx + QEMU
→ linux/amd64 + linux/arm64
→ GHCR latest / SHA / SemVer
```

`compose.prod.yaml`은 로컬 빌드 대신 GHCR 이미지를 사용하고, K3s Deployment도 같은 멀티 아키텍처 이미지를 pull한다.

## 4. K3s 애플리케이션 구조

```text
Mac browser :8081
→ UTM guest :80
→ Traefik Ingress
├→ app.platform.local
│  → platform-lab/app Service
│  → Node.js Deployment
│  → db Service
│  → PostgreSQL StatefulSet / PVC
└→ blog.platform.local
   → blog/blog Service
   → Next.js Blog Deployment
```

`platform-lab` namespace는 데모 앱과 데이터베이스를, `blog` namespace는 별도 블로그 워크로드를 관리한다. Traefik은 모든 HTTP 요청을 같은 포트에서 받고 `Host` 헤더로 Service를 선택한다.

## 5. K3s 모니터링 구조

```text
Node.js Pod /metrics     Next.js Blog Pod /metrics
→ app ServiceMonitor    → blog ServiceMonitor
└───────────────┬───────────────┘
                → Prometheus Operator
                → Prometheus
                  ├→ Platform App Overview
                  ├→ Blog Overview
                  └→ PrometheusRule → Alertmanager
```

`kube-prometheus-stack`은 Prometheus Operator, Prometheus, Grafana, Alertmanager, kube-state-metrics와 node-exporter를 Helm release로 관리한다.

## 6. 설정과 데이터 관리

| 목적 | Docker Compose | Kubernetes |
|---|---|---|
| 일반 설정 | `.env` | ConfigMap |
| 민감 정보 | `.env` | Secret |
| 데이터베이스 | named volume | StatefulSet + PVC |
| 외부 접속 | `ports` | Service + Ingress |
| 상태 검사 | healthcheck | startup/readiness/liveness probe |
| 애플리케이션 교체 | Compose recreate | Deployment rollout |

실제 Secret 값, `.env`, 백업 파일은 Git에 커밋하지 않는다. Dashboard JSON·ConfigMap·ServiceMonitor처럼 재현에 필요하고 민감하지 않은 설정은 저장소에서 관리한다.

## 7. 주요 디렉터리

```text
.
├── app/                         # Node.js 데모 앱
├── db/init/                     # PostgreSQL 초기화 SQL
├── grafana/dashboards/          # 대시보드 source of truth
├── helm/                        # kube-prometheus-stack values
├── k8s/                         # platform-lab 기본 리소스
│   ├── blog/                   # 블로그 배포·모니터링
│   └── monitoring/             # 데모 앱 모니터링·경고
├── monitoring/                  # Compose Prometheus·Grafana
├── compose.yaml
└── compose.prod.yaml
```

실행·운영 명령은 [운영 명령과 점검 방법](./02-operations.md), K3s 리소스는 [K3s 기반 Kubernetes 배포](./08-k3s.md), 블로그 흐름은 [Next.js 블로그 K3s 배포와 모니터링](./10-blog-k3s.md)에서 이어서 설명한다.
