# Container Platform Lab

Docker Compose 기반으로 nginx, Node.js, PostgreSQL 등을 구성하며 컨테이너 운영 환경을 학습하는 실습 저장소입니다.

## Current Stack

- Docker
- Docker Compose
- nginx
- Node.js
- PostgreSQL

## Architecture

```text
Client
-> nginx
-> Node.js app
-> PostgreSQL
```

## Project Structure

```text
.
├── app
│   ├── .dockerignore
│   ├── Dockerfile
│   ├── package-lock.json
│   ├── package.json
│   └── server.js
├── compose.yaml
├── nginx
│   └── default.conf
├── .env.example
├── .gitignore
└── README.md
```

## Run

```bash
cp .env.example .env
docker compose up -d --build
```

## Check Status

```bash
docker compose ps
```

## Test

```bash
curl http://localhost:8080/
```

Expected result:

```text
Hello from Node app container
Visit count: 1
```

## Logs

```bash
docker compose logs -f
docker compose logs app
docker compose logs nginx
docker compose logs db
```

## Stop

```bash
docker compose down
```

## Reset DB

```bash
docker compose down -v
```

## Notes

`.env` 파일은 Git에 포함하지 않습니다.

실제 환경변수는 `.env.example`을 복사해서 사용합니다.

```bash
cp .env.example .env
```

## Current Features

- nginx reverse proxy
- Node.js app container
- PostgreSQL container
- Docker Compose service networking
- Named volume for PostgreSQL data
- Environment variable separation with `.env`

## Next Steps

- Add healthcheck
- Add depends_on condition
- Add DB initialization SQL
- Add volume backup and restore practice
- Add Prometheus
- Add Grafana
