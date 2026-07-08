# 프로젝트 구조와 아키텍처

## 목적

이 프로젝트는 Docker Compose를 사용해 작은 컨테이너 기반 서비스 구조를 직접 구성하고 운영하는 실습 저장소입니다.

현재 구성은 다음 흐름을 기준으로 합니다.

```text
Client
-> nginx
-> Node.js app
-> PostgreSQL
```

## 구성 요소

### nginx

외부 요청을 받는 reverse proxy 역할을 합니다.

현재 클라이언트는 `localhost:8080`으로 접속하고, nginx는 요청을 app 컨테이너로 전달합니다.

### Node.js app

간단한 HTTP 서버입니다.

주요 역할은 다음과 같습니다.

- `/health` 요청에 `OK` 응답
- 기본 `/` 요청 시 PostgreSQL에 visit row 삽입
- 현재 visit count 조회 후 응답

### PostgreSQL

방문 기록을 저장하는 데이터베이스입니다.

`visits` 테이블을 사용합니다.

```sql
CREATE TABLE IF NOT EXISTS visits (
  id SERIAL PRIMARY KEY,
  created_at TIMESTAMPTZ DEFAULT now()
);
```

## Docker Compose 서비스 관계

Compose 서비스는 다음 순서로 의존합니다.

```text
db healthy
-> app start
-> app healthy
-> nginx start
```

이를 위해 `depends_on.condition: service_healthy`를 사용합니다.

## 데이터 저장 방식

PostgreSQL 데이터는 named volume에 저장합니다.

```yaml
volumes:
  db-data:
```

컨테이너는 삭제되어도 되지만, 데이터는 volume에 남아야 합니다.

단, 다음 명령은 volume까지 삭제합니다.

```bash
docker compose down -v
```

## 프로젝트 디렉터리 구조

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
├── nginx
│   └── default.conf
├── .env.example
├── .gitignore
└── README.md
```

## 현재 구현된 운영 요소

- nginx reverse proxy
- Node.js app 컨테이너 빌드
- PostgreSQL 컨테이너 구성
- Docker Compose 서비스 네트워킹
- PostgreSQL named volume
- app healthcheck
- db healthcheck
- service_healthy 기반 시작 순서 제어
- PostgreSQL init SQL
- `TIMESTAMPTZ` 기반 timestamp 처리
- `pg_dump --data-only` 기반 백업/복구 실습
