# PostgreSQL 백업과 복구

이 문서는 PostgreSQL 데이터를 `pg_dump`로 백업하고 복구하는 실습을 정리합니다.

## 목표

```text
1. 현재 DB 데이터 확인
2. pg_dump로 백업 파일 생성
3. docker compose down -v로 DB volume 삭제
4. docker compose up -d --build로 빈 DB 재생성
5. 백업 파일로 데이터 복구
6. visits count가 복원되는지 확인
```

## 백업 파일 위치

로컬 백업 파일은 `backups/` 디렉터리에 저장합니다.

```bash
mkdir -p backups
```

`backups/`는 `.gitignore`에 추가되어 있습니다.

```gitignore
# Local database backup files
backups/
```

DB dump 파일에는 민감한 데이터가 들어갈 수 있으므로 Git에 올리지 않습니다.

## 현재 데이터 확인

```bash
docker compose exec db psql -U appuser -d appdb -c "SELECT COUNT(*) FROM visits;"
```

실습에서는 count가 3인 상태에서 백업을 진행했습니다.

## 전체 dump

전체 dump는 스키마와 데이터를 모두 포함합니다.

```bash
docker compose exec -T db pg_dump -U appuser -d appdb > backups/appdb.sql
```

여기서 `-T`는 pseudo-TTY를 끄는 옵션입니다.

파일 리다이렉션을 사용할 때는 `-T`를 붙이는 것이 좋습니다.

```text
docker compose exec db ...
= TTY를 열고 명령 실행

docker compose exec -T db ...
= TTY 없이 명령 실행
= 파일 리다이렉션과 백업/복구에 적합
```

## 전체 dump 복구 시 충돌

현재 프로젝트는 `db/init/01-create-visits.sql`로 스키마를 먼저 생성합니다.

따라서 전체 dump를 이미 초기화된 DB에 복구하면 다음 오류가 발생할 수 있습니다.

```text
ERROR: relation "visits" already exists
ERROR: relation "visits_id_seq" already exists
ERROR: multiple primary keys for table "visits" are not allowed
```

원인은 다음과 같습니다.

```text
1. docker compose up 시 init SQL이 visits 테이블을 생성
2. 전체 dump 안에도 CREATE TABLE / CREATE SEQUENCE / PRIMARY KEY가 포함됨
3. 이미 존재하는 객체를 다시 만들려고 해서 충돌
```

실습 중에는 `COPY 3`이 출력되어 데이터 자체는 일부 복구되었지만, 전체 restore 방식은 이 프로젝트 구조와 깔끔하게 맞지 않습니다.

## data-only 백업

이 프로젝트에서는 스키마를 Git으로 관리합니다.

```text
스키마:
db/init/01-create-visits.sql

데이터:
pg_dump --data-only 백업 파일
```

따라서 데이터만 백업하는 방식이 더 적합합니다.

```bash
docker compose exec -T db pg_dump -U appuser -d appdb --data-only > backups/appdb-data.sql
```

`--data-only` dump는 테이블 생성 SQL 대신 데이터 복구에 필요한 내용이 중심입니다.

예를 들면 다음과 같은 내용입니다.

```text
COPY public.visits ...
SELECT pg_catalog.setval(...)
```

## 복구 흐름

DB volume을 삭제합니다.

```bash
docker compose down -v
```

서비스를 다시 올립니다.

```bash
docker compose up -d --build
```

이 시점에 init SQL이 `visits` 테이블만 다시 생성합니다.

초기 count를 확인합니다.

```bash
docker compose exec db psql -U appuser -d appdb -c "SELECT COUNT(*) FROM visits;"
```

예상 결과입니다.

```text
count = 0
```

데이터 전용 백업을 복구합니다.

```bash
docker compose exec -T db psql -U appuser -d appdb < backups/appdb-data.sql
```

복구 후 count를 확인합니다.

```bash
docker compose exec db psql -U appuser -d appdb -c "SELECT COUNT(*) FROM visits;"
```

예상 결과입니다.

```text
count = 3
```

## 정리

```text
컨테이너는 삭제되어도 된다.
데이터는 volume에 저장된다.
volume은 백업/복구 가능해야 한다.
```

이 프로젝트의 현재 기준입니다.

```text
스키마는 Git으로 관리한다.
데이터는 pg_dump --data-only로 백업한다.
백업 파일은 Git에 올리지 않는다.
```
