# Container Platform Lab

Docker Compose로 구성한 nginx, Node.js, PostgreSQL, Prometheus, Grafana 스택을 CI/CD와 버전 기반 배포까지 확장하고, 동일한 애플리케이션을 K3s 환경에 배포하며 Kubernetes의 핵심 리소스를 학습하는 실습 저장소입니다.

## 아키텍처

```text
Docker Compose
Client
→ nginx
→ Node.js app
→ PostgreSQL

Node.js /metrics
→ Prometheus
→ Grafana

K3s
Client
→ Traefik Ingress
→ app Service
→ Node.js Deployment
→ db Service
→ PostgreSQL StatefulSet / PVC

GitHub Actions
→ Compose integration test
→ Kubernetes manifest validation
→ GHCR multi-architecture image
```

## 기술 스택

- Docker / Docker Compose
- K3s / Kubernetes
- Traefik Ingress
- nginx
- Node.js 24
- PostgreSQL
- Prometheus / Grafana
- GitHub Actions
- GitHub Container Registry
- Kubeconform

## 빠른 실행

개발 구성은 로컬에서 애플리케이션 이미지를 빌드합니다.

```bash
cp .env.example .env
make up
make ps
```

접속 주소:

```text
Application: http://localhost:8080
Prometheus:  http://localhost:9090
Grafana:     http://localhost:3001
```

중지:

```bash
make down
```

## GHCR 이미지 기반 실행

배포 구성은 GHCR에 게시된 이미지를 사용합니다. 기본 태그는 latest입니다.

```bash
docker compose -f compose.yaml -f compose.prod.yaml pull app
docker compose -f compose.yaml -f compose.prod.yaml up -d
```

특정 버전으로 고정하려면 APP_IMAGE_TAG를 지정합니다.

```bash
APP_IMAGE_TAG=0.1.0 docker compose \
  -f compose.yaml \
  -f compose.prod.yaml \
  up -d
```

게시 이미지:

```text
ghcr.io/maackia/container-platform-lab-app
```

지원 플랫폼:

```text
linux/amd64
linux/arm64
```

## K3s 배포

K3s와 `platform-secret`을 준비한 뒤 전체 매니페스트를 적용합니다.

```bash
kubectl apply -f k8s/
kubectl get all -n platform-lab
kubectl get ingress,pvc -n platform-lab
```

배포 경로는 다음과 같습니다.

```text
platform.local
→ Traefik
→ app Service
→ Node.js Pod
→ PostgreSQL StatefulSet
```

Secret 생성, UTM 포트 포워딩, 상태 확인 방법은 [K3s 기반 Kubernetes 배포](./docs/08-k3s.md)에 정리합니다.

## 주요 기능

- nginx reverse proxy와 Node.js / PostgreSQL 3-tier 구성
- healthcheck와 service_healthy 기반 시작 순서 제어
- PostgreSQL init SQL, named volume, data-only 백업/복구
- Prometheus 메트릭 수집과 Grafana 자동 provisioning
- GitHub Actions 기반 문법·Compose·이미지 빌드 검증
- 전체 Compose 스택 통합 테스트와 readiness 재시도
- GHCR latest, 커밋 SHA, SemVer 이미지 게시
- amd64 / arm64 멀티 아키텍처 이미지
- compose.prod.yaml 기반 버전 고정 배포와 롤백
- K3s Namespace, Deployment, Service, ConfigMap, Secret 구성
- PostgreSQL StatefulSet와 local-path PVC
- Traefik Ingress와 readiness/liveness probe
- Kubeconform 기반 Kubernetes 매니페스트 CI 검증

## 프로젝트 구조

```text
.
├── .github/workflows
│   ├── ci.yml
│   └── publish.yml
├── app
├── db/init
├── docs
│   ├── README.md
│   ├── 01-architecture.md
│   ├── 02-operations.md
│   ├── 03-database-init-and-timezone.md
│   ├── 04-backup-and-restore.md
│   ├── 05-monitoring.md
│   ├── 06-ci-cd.md
│   ├── 07-production-compose.md
│   └── 08-k3s.md
├── k8s
│   ├── 00-namespace.yaml
│   ├── ...
│   └── 09-app-ingress.yaml
├── monitoring
├── nginx
├── compose.yaml
├── compose.prod.yaml
├── Makefile
└── README.md
```

## 문서

자세한 설명과 실습 기록은 [문서 목차](./docs/README.md)에 정리합니다.

- [프로젝트 구조와 아키텍처](./docs/01-architecture.md)
- [운영 명령과 점검 방법](./docs/02-operations.md)
- [데이터베이스 초기화와 시간대 정책](./docs/03-database-init-and-timezone.md)
- [PostgreSQL 백업과 복구](./docs/04-backup-and-restore.md)
- [Prometheus와 Grafana 모니터링](./docs/05-monitoring.md)
- [GitHub Actions CI와 GHCR 이미지 게시](./docs/06-ci-cd.md)
- [배포용 Compose와 버전 롤백](./docs/07-production-compose.md)
- [K3s 기반 Kubernetes 배포](./docs/08-k3s.md)

## 현재 완료 범위

```text
Docker Compose 스택
→ 모니터링
→ CI 및 통합 테스트
→ GHCR 멀티 아키텍처 게시
→ SemVer v0.1.0
→ 버전 고정 배포와 SHA 롤백
→ K3s 애플리케이션·데이터베이스 배포
→ Traefik Ingress와 PVC
→ Kubernetes 매니페스트 CI 검증
```

.env, backups/, 실제 Secret 값은 Git에 포함하지 않습니다.
