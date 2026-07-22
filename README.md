# Container Platform Lab

Docker Compose 기반으로 nginx, Node.js, PostgreSQL, Prometheus, Grafana를 구성하고, CI·컨테이너 이미지 게시·버전 기반 배포와 롤백까지 학습하는 실습 저장소입니다.

## 아키텍처

```text
Client
-> nginx
-> Node.js app
-> PostgreSQL

Node.js /metrics
-> Prometheus
-> Grafana

GitHub Actions
-> CI / integration test
-> GHCR multi-architecture image
-> production Compose deployment
```

## 기술 스택

- Docker / Docker Compose
- nginx
- Node.js 24
- PostgreSQL
- Prometheus / Grafana
- GitHub Actions
- GitHub Container Registry

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
│   └── 07-production-compose.md
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

## 현재 완료 범위

```text
Docker Compose 스택
-> 모니터링
-> CI 및 통합 테스트
-> GHCR 멀티 아키텍처 게시
-> SemVer v0.1.0
-> 버전 고정 배포
-> SHA 태그 롤백 검증
```

.env와 backups/는 Git에 포함하지 않습니다.
