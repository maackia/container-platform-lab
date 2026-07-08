# Container Platform Lab

Docker Compose 기반으로 nginx, Node.js, PostgreSQL 등을 구성하며 컨테이너 운영 환경을 학습하는 실습 저장소입니다.

이 저장소는 단순 Compose 예제를 넘어, healthcheck, startup dependency, DB initialization SQL, volume, 그리고 추후 Prometheus/Grafana 모니터링까지 확장하는 것을 목표로 합니다.

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
├── db
│   └── init
│       └── 01-create-visits.sql
├── nginx
│   └── default.conf
├── .env.example
├── .gitignore
└── README.md
```

## Features

- nginx reverse proxy
- Node.js app container
- PostgreSQL container
- Docker Compose service networking
- Named volume for PostgreSQL data
- Environment variable separation with `.env`
- App health endpoint: `/health`
- App and database healthchecks
- `depends_on` with `service_healthy` conditions
- PostgreSQL schema initialization using `db/init/01-create-visits.sql`
- PostgreSQL inspection using `docker compose exec` and `psql`
- Data-only PostgreSQL backup and restore practice using `pg_dump`

## Run

```bash
cp .env.example .env
docker compose up -d --build
```

## Check Status

```bash
docker compose ps
```

Expected status:

```text
compose-db      Up ... (healthy)
compose-app     Up ... (healthy)
compose-nginx   Up ...
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

The visit count increases on each request.

Health endpoint:

```bash
curl http://localhost:8080/health
```

Expected result:

```text
OK
```

## Inspect PostgreSQL

Open a shell inside the running PostgreSQL service container:

```bash
docker compose exec db sh
```

Connect to PostgreSQL from inside the container:

```bash
psql -U appuser -d appdb
```

Useful `psql` commands:

```sql
\dt
\d visits
SELECT COUNT(*) FROM visits;
SELECT * FROM visits ORDER BY id DESC LIMIT 5;
```

You can also run SQL directly without entering an interactive shell:

```bash
docker compose exec db psql -U appuser -d appdb -c "SELECT COUNT(*) FROM visits;"
docker compose exec db psql -U appuser -d appdb -c "SELECT id, created_at FROM visits ORDER BY id DESC LIMIT 5;"
```

To verify the request flow, compare the count before and after sending app requests:

```bash
docker compose exec db psql -U appuser -d appdb -c "SELECT COUNT(*) FROM visits;"

curl http://localhost:8080/
curl http://localhost:8080/
curl http://localhost:8080/

docker compose exec db psql -U appuser -d appdb -c "SELECT COUNT(*) FROM visits;"
```

Expected flow:

```text
curl request
-> nginx
-> app
-> PostgreSQL INSERT
-> visits count increases
```

## Backup and Restore

Local backup files are stored under `backups/`, which is ignored by Git because database dumps can contain sensitive data.

Create the local backup directory:

```bash
mkdir -p backups
```

Check the current row count:

```bash
docker compose exec db psql -U appuser -d appdb -c "SELECT COUNT(*) FROM visits;"
```

Create a data-only backup:

```bash
docker compose exec -T db pg_dump -U appuser -d appdb --data-only > backups/appdb-data.sql
```

`-T` disables pseudo-TTY allocation. This is useful when redirecting command output to a file.

Reset the database volume:

```bash
docker compose down -v
docker compose up -d --build
```

After reset, the init SQL recreates the table, but the data is empty:

```bash
docker compose exec db psql -U appuser -d appdb -c "SELECT COUNT(*) FROM visits;"
```

Restore data from the backup:

```bash
docker compose exec -T db psql -U appuser -d appdb < backups/appdb-data.sql
```

Verify that the count is restored:

```bash
docker compose exec db psql -U appuser -d appdb -c "SELECT COUNT(*) FROM visits;"
```

### Full dump vs data-only dump

A full dump includes schema and data:

```bash
docker compose exec -T db pg_dump -U appuser -d appdb > backups/appdb.sql
```

This can fail when restoring into a database where the schema already exists, because `db/init/01-create-visits.sql` creates the `visits` table at startup.

For this project, the schema is managed by Git under `db/init`, so data-only backup is the cleaner fit:

```bash
docker compose exec -T db pg_dump -U appuser -d appdb --data-only > backups/appdb-data.sql
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

This removes containers and the Compose network, but keeps the PostgreSQL volume.

## Reset DB

```bash
docker compose down -v
```

This removes the PostgreSQL named volume as well. The next `docker compose up -d --build` run will initialize the database again using SQL files under `db/init`.

## Database Initialization

PostgreSQL initialization SQL is stored in:

```text
db/init/01-create-visits.sql
```

This file is mounted into the PostgreSQL container:

```text
/docker-entrypoint-initdb.d
```

The SQL files in this directory run only when the PostgreSQL data directory is first initialized. If the existing `db-data` volume already exists, the init SQL will not run again unless the volume is removed.

## Timezone Policy

`created_at` uses `TIMESTAMPTZ DEFAULT now()`.

The database timezone is kept as UTC. Store timestamps in UTC and convert them at query, API, or UI display time when a local timezone such as `Asia/Seoul` is needed.

Example:

```sql
SELECT
  id,
  created_at,
  created_at AT TIME ZONE 'Asia/Seoul' AS created_at_kst
FROM visits
ORDER BY id DESC
LIMIT 5;
```

## Notes

`.env` 파일은 Git에 포함하지 않습니다.

실제 환경변수는 `.env.example`을 복사해서 사용합니다.

```bash
cp .env.example .env
```

`backups/` 디렉터리는 Git에 포함하지 않습니다. 로컬 DB dump 파일에는 민감한 데이터가 들어갈 수 있습니다.

## Current Learning Progress

Completed:

- Basic Docker container execution
- Port mapping
- Docker bridge network basics
- Docker Compose service networking
- nginx reverse proxy to app service
- Node.js app container build
- PostgreSQL service integration
- Named volume for DB persistence
- `.env` / `.env.example` separation
- App and DB healthchecks
- Startup ordering with `depends_on.condition: service_healthy`
- DB schema initialization with SQL
- Timestamp handling with `TIMESTAMPTZ` and UTC
- PostgreSQL inspection with `docker compose exec` and `psql`
- Database backup and restore with `pg_dump --data-only`
- Git ignore policy for local database backup files

## Next Steps

- Add Prometheus
- Add Grafana
