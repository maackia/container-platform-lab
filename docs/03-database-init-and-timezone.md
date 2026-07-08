# 데이터베이스 초기화와 시간대 정책

이 문서는 PostgreSQL 초기화 SQL과 timestamp 처리 방식을 정리합니다.

## DB 초기화 SQL

PostgreSQL 초기화 SQL은 다음 경로에 있습니다.

```text
db/init/01-create-visits.sql
```

현재 내용입니다.

```sql
-- db/init/01-create-visits.sql
-- visits 테이블 생성을 app/server.js에서 DB 초기화 SQL로 분리
-- created_at은 시간대 처리를 위해 TIMESTAMPTZ 사용

CREATE TABLE IF NOT EXISTS visits (
  id SERIAL PRIMARY KEY,
  created_at TIMESTAMPTZ DEFAULT now()
);
```

## Compose 마운트

`compose.yaml`에서 이 디렉터리를 PostgreSQL 컨테이너의 초기화 디렉터리로 마운트합니다.

```yaml
volumes:
  - ./db/init:/docker-entrypoint-initdb.d:ro
```

의미는 다음과 같습니다.

```text
./db/init
= 호스트의 초기화 SQL 디렉터리

/docker-entrypoint-initdb.d
= PostgreSQL 공식 이미지가 초기화 시 읽는 디렉터리

:ro
= read-only 마운트
```

## init SQL 실행 시점

`/docker-entrypoint-initdb.d`의 SQL 파일은 PostgreSQL 데이터 디렉터리가 처음 생성될 때만 실행됩니다.

즉, 이미 `db-data` volume이 존재하면 SQL 파일을 수정해도 자동으로 다시 실행되지 않습니다.

초기화 SQL을 다시 적용하려면 volume을 삭제해야 합니다.

```bash
docker compose down -v
docker compose up -d --build
```

주의할 점입니다.

```text
docker compose down
= 컨테이너와 네트워크 삭제
= DB volume 유지

docker compose down -v
= 컨테이너와 네트워크 삭제
= DB volume까지 삭제
= DB 데이터 초기화
```

## app 코드에서 스키마 생성을 제거한 이유

초기 구현에서는 app이 실행될 때 `CREATE TABLE IF NOT EXISTS`를 실행했습니다.

이후 스키마 생성을 `db/init/01-create-visits.sql`로 분리했습니다.

이렇게 나누면 역할이 명확해집니다.

```text
app/server.js
= 요청 처리, DB insert/select

db/init/01-create-visits.sql
= DB schema 초기화
```

## 시간대 정책

`created_at`은 다음 타입을 사용합니다.

```sql
created_at TIMESTAMPTZ DEFAULT now()
```

이전에는 다음 타입이었습니다.

```sql
created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
```

`TIMESTAMP`는 timezone 정보가 없는 날짜/시간입니다.

반면 `TIMESTAMPTZ`는 PostgreSQL에서 timestamp를 시간대 처리와 함께 다루기에 더 적합합니다.

## UTC 기준 저장

DB timezone은 UTC로 유지합니다.

```sql
SHOW timezone;
```

예상 결과입니다.

```text
UTC
```

현재 DB 시각 확인입니다.

```sql
SELECT now();
```

예시입니다.

```text
2026-07-08 05:12:26.425301+00
```

운영 기준은 다음과 같습니다.

```text
DB 저장 기준
= UTC

사용자 화면 표시
= 필요한 시점에 Asia/Seoul 등 로컬 시간대로 변환
```

## 한국 시간으로 조회하기

```sql
SELECT
  id,
  created_at,
  created_at AT TIME ZONE 'Asia/Seoul' AS created_at_kst
FROM visits
ORDER BY id DESC
LIMIT 5;
```

## 정리

```text
스키마 생성은 init SQL에서 관리
앱은 요청 처리와 DB 사용에 집중
timestamp는 TIMESTAMPTZ 사용
DB 저장 기준은 UTC
로컬 시간 표시는 조회/API/UI 단계에서 변환
```
