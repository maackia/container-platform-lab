# Container Platform Lab

Docker Compose 기반으로 `nginx`, `Node.js`, `PostgreSQL`을 구성하며 컨테이너 운영 환경을 학습하는 실습 저장소입니다.

이 프로젝트는 단순히 컨테이너를 실행하는 것을 넘어, healthcheck, 서비스 시작 순서, DB 초기화, volume, 백업/복구, 모니터링까지 단계적으로 확장하는 것을 목표로 합니다.

## 아키텍처

```text
Client
-> nginx
-> Node.js app
-> PostgreSQL
```

## 기술 스택

- Docker
- Docker Compose
- nginx
- Node.js
- PostgreSQL

## 빠른 실행

```bash
cp .env.example .env
docker compose up -d --build
```

상태 확인:

```bash
docker compose ps
```

요청 테스트:

```bash
curl http://localhost:8080/
curl http://localhost:8080/health
```

중지:

```bash
docker compose down
```

DB volume까지 초기화:

```bash
docker compose down -v
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

## 프로젝트 구조

```text
.
├── app
│   ├── .dockerignore
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
│   └── 04-backup-and-restore.md
├── nginx
│   └── default.conf
├── .env.example
├── .gitignore
└── README.md
```

## 문서

자세한 설명과 실습 기록은 `docs/`에 정리합니다.

- [문서 목차](./docs/README.md)
- [프로젝트 구조와 아키텍처](./docs/01-architecture.md)
- [운영 명령과 점검 방법](./docs/02-operations.md)
- [데이터베이스 초기화와 시간대 정책](./docs/03-database-init-and-timezone.md)
- [PostgreSQL 백업과 복구](./docs/04-backup-and-restore.md)

## 운영 명령 요약

로그 확인:

```bash
docker compose logs -f
```

DB 접속:

```bash
docker compose exec db psql -U appuser -d appdb
```

DB row 개수 확인:

```bash
docker compose exec db psql -U appuser -d appdb -c "SELECT COUNT(*) FROM visits;"
```

데이터 백업:

```bash
mkdir -p backups
docker compose exec -T db pg_dump -U appuser -d appdb --data-only > backups/appdb-data.sql
```

데이터 복구:

```bash
docker compose exec -T db psql -U appuser -d appdb < backups/appdb-data.sql
```

## Git 제외 대상

`.env`와 `backups/`는 Git에 포함하지 않습니다.

```text
.env
backups/
```

`.env`에는 로컬 환경변수가 들어가고, `backups/`에는 DB dump 파일이 들어갈 수 있기 때문입니다.

## 진행 상황

완료:

- Compose 기반 nginx / app / db 구성
- healthcheck와 시작 순서 제어
- PostgreSQL init SQL 분리
- UTC 기준 timestamp 처리
- psql 기반 DB 점검
- data-only 백업/복구 실습
- README 슬림화 및 docs 분리

다음 단계:

- Prometheus 추가
- Grafana 추가
