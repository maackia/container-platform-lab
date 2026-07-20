# Container Platform Lab

Docker Compose 기반으로 `nginx`, `Node.js`, `PostgreSQL`, `Prometheus`, `Grafana`를 구성하며 컨테이너 운영 환경을 학습하는 실습 저장소입니다.

이 프로젝트는 단순히 컨테이너를 실행하는 것을 넘어, healthcheck, 서비스 시작 순서, DB 초기화, volume, 백업/복구, 모니터링까지 단계적으로 확장하는 것을 목표로 합니다.

## 아키텍처

```text
Client
-> nginx
-> Node.js app
-> PostgreSQL

Node.js /metrics
-> Prometheus
-> Grafana
```

## 기술 스택

- Docker
- Docker Compose
- nginx
- Node.js
- PostgreSQL
- Prometheus
- Grafana

## 빠른 실행

```bash
cp .env.example .env
make up
```

상태 확인:

```bash
make ps
```

접속 주소:

```text
Application: http://localhost:8080
Prometheus:  http://localhost:9090
Grafana:     http://localhost:3001
```

요청 테스트:

```bash
curl http://localhost:8080/
curl http://localhost:8080/health
curl http://localhost:8080/metrics
```

중지:

```bash
make down
```

모든 Compose volume까지 초기화:

```bash
make reset
```

## 주요 기능

- nginx reverse proxy
- Node.js app 컨테이너 빌드
- PostgreSQL 컨테이너 구성
- Docker Compose 서비스 네트워킹
- PostgreSQL named volume
- `.env` / `.env.example` 환경변수 분리
- app / db healthcheck
- `depends_on.condition: service_healthy` 기반 시작 순서 제어
- PostgreSQL init SQL을 통한 schema 초기화
- `TIMESTAMPTZ`와 UTC 기준 timestamp 처리
- `docker compose exec`와 `psql`을 통한 DB 점검
- `pg_dump --data-only` 기반 데이터 백업/복구
- Node.js 기본 메트릭과 애플리케이션 메트릭 노출
- Prometheus 기반 메트릭 수집
- Grafana 데이터소스와 대시보드 자동 provisioning

## 프로젝트 구조

```text
.
├── app
│   ├── Dockerfile
│   ├── package-lock.json
│   ├── package.json
│   └── server.js
├── compose.yaml
├── db
│   └── init
│       └── 01-create-visits.sql
├── docs
│   ├── README.md
│   ├── 01-architecture.md
│   ├── 02-operations.md
│   ├── 03-database-init-and-timezone.md
│   ├── 04-backup-and-restore.md
│   ├── 05-monitoring.md
│   └── examples
│       └── container-platform-lab-dashboard.jsonc
├── monitoring
│   ├── grafana
│   │   ├── dashboards
│   │   └── provisioning
│   └── prometheus
│       └── prometheus.yml
├── nginx
│   └── default.conf
├── .env.example
├── Makefile
└── README.md
```

## 문서

자세한 설명과 실습 기록은 `docs/`에 정리합니다.

- [문서 목차](./docs/README.md)
- [프로젝트 구조와 아키텍처](./docs/01-architecture.md)
- [운영 명령과 점검 방법](./docs/02-operations.md)
- [데이터베이스 초기화와 시간대 정책](./docs/03-database-init-and-timezone.md)
- [PostgreSQL 백업과 복구](./docs/04-backup-and-restore.md)
- [Prometheus와 Grafana 모니터링](./docs/05-monitoring.md)

## 운영 명령 요약

```bash
make help       # 사용 가능한 명령 확인
make logs       # 전체 로그 확인
make db         # PostgreSQL 접속
make db-count   # visits row 개수 확인
make backup     # PostgreSQL data-only 백업
make restore    # PostgreSQL 데이터 복구
```

## Git 제외 대상

`.env`와 `backups/`는 Git에 포함하지 않습니다.

```text
.env
backups/
```

## 진행 상황

완료:

- Compose 기반 nginx / app / db 구성
- healthcheck와 시작 순서 제어
- PostgreSQL init SQL 분리
- UTC 기준 timestamp 처리
- psql 기반 DB 점검
- data-only 백업/복구 실습
- Compose 네트워크 정리와 Makefile 추가
- Prometheus 메트릭 수집
- Grafana 데이터소스 및 대시보드 provisioning
- README 슬림화 및 docs 분리
