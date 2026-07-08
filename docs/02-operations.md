# 운영 명령과 점검 방법

이 문서는 Compose 기반 서비스를 실행하고, 상태를 확인하고, 로그와 DB 상태를 점검하는 명령을 정리합니다.

## 실행

```bash
cp .env.example .env
docker compose up -d --build
```

## 상태 확인

```bash
docker compose ps
```

기대 상태입니다.

```text
compose-db      Up ... (healthy)
compose-app     Up ... (healthy)
compose-nginx   Up ...
```

`db`와 `app`이 `healthy` 상태인지 확인합니다.

## 요청 테스트

기본 요청입니다.

```bash
curl http://localhost:8080/
```

예상 응답입니다.

```text
Hello from Node app container
Visit count: 1
```

health endpoint 확인입니다.

```bash
curl http://localhost:8080/health
```

예상 응답입니다.

```text
OK
```

## 로그 확인

전체 로그를 follow 모드로 확인합니다.

```bash
docker compose logs -f
```

서비스별 로그 확인입니다.

```bash
docker compose logs app
docker compose logs nginx
docker compose logs db
```

## PostgreSQL 접속

실행 중인 DB 컨테이너 안으로 들어갑니다.

```bash
docker compose exec db sh
```

컨테이너 내부에서 PostgreSQL에 접속합니다.

```bash
psql -U appuser -d appdb
```

psql 프롬프트가 나오면 정상입니다.

```text
appdb=#
```

## psql 기본 명령

테이블 목록 확인입니다.

```sql
\dt
```

`visits` 테이블 구조 확인입니다.

```sql
\d visits
```

row 개수 확인입니다.

```sql
SELECT COUNT(*) FROM visits;
```

최근 row 확인입니다.

```sql
SELECT id, created_at
FROM visits
ORDER BY id DESC
LIMIT 5;
```

## 한 줄로 SQL 실행

컨테이너 shell이나 psql에 직접 들어가지 않고도 SQL을 실행할 수 있습니다.

```bash
docker compose exec db psql -U appuser -d appdb -c "SELECT COUNT(*) FROM visits;"
```

최근 row 확인입니다.

```bash
docker compose exec db psql -U appuser -d appdb -c "SELECT id, created_at FROM visits ORDER BY id DESC LIMIT 5;"
```

## 요청 흐름 확인

요청 전 count를 확인합니다.

```bash
docker compose exec db psql -U appuser -d appdb -c "SELECT COUNT(*) FROM visits;"
```

앱에 요청을 보냅니다.

```bash
curl http://localhost:8080/
curl http://localhost:8080/
curl http://localhost:8080/
```

다시 count를 확인합니다.

```bash
docker compose exec db psql -U appuser -d appdb -c "SELECT COUNT(*) FROM visits;"
```

count가 3 증가하면 다음 흐름이 정상입니다.

```text
curl request
-> nginx
-> app
-> PostgreSQL INSERT
-> visits count 증가
```

## 중지

```bash
docker compose down
```

컨테이너와 Compose 네트워크를 삭제하지만, PostgreSQL volume은 유지됩니다.

## DB 초기화

```bash
docker compose down -v
```

컨테이너, 네트워크, named volume을 함께 삭제합니다.

이 명령을 실행하면 DB 데이터가 초기화됩니다.
