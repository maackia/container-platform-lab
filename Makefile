.PHONY: help up down restart ps logs app-logs nginx-logs db-logs db db-count db-recent backup restore reset clean

BACKUP_FILE ?= backups/appdb-data.sql

help:
	@echo "사용 가능한 명령:"
	@echo "  make up          - 컨테이너 빌드 후 백그라운드 실행"
	@echo "  make down        - 컨테이너와 네트워크 중지/삭제, volume 유지"
	@echo "  make restart     - down 후 up 실행"
	@echo "  make ps          - Compose 서비스 상태 확인"
	@echo "  make logs        - 전체 로그 follow"
	@echo "  make app-logs    - app 로그 확인"
	@echo "  make nginx-logs  - nginx 로그 확인"
	@echo "  make db-logs     - db 로그 확인"
	@echo "  make db          - PostgreSQL psql 접속"
	@echo "  make db-count    - visits row 개수 확인"
	@echo "  make db-recent   - 최근 visits row 5개 확인"
	@echo "  make backup      - PostgreSQL data-only 백업"
	@echo "  make restore     - BACKUP_FILE로 PostgreSQL 데이터 복구"
	@echo "  make reset       - volume 포함 전체 초기화 후 재실행"
	@echo "  make clean       - 컨테이너와 네트워크 삭제, volume 유지"

up:
	docker compose up -d --build

down:
	docker compose down

restart: down up

ps:
	docker compose ps

logs:
	docker compose logs -f

app-logs:
	docker compose logs app

nginx-logs:
	docker compose logs nginx

db-logs:
	docker compose logs db

db:
	docker compose exec db psql -U appuser -d appdb

db-count:
	docker compose exec db psql -U appuser -d appdb -c "SELECT COUNT(*) FROM visits;"

db-recent:
	docker compose exec db psql -U appuser -d appdb -c "SELECT id, created_at FROM visits ORDER BY id DESC LIMIT 5;"

backup:
	mkdir -p backups
	docker compose exec -T db pg_dump -U appuser -d appdb --data-only > $(BACKUP_FILE)
	@echo "백업 완료: $(BACKUP_FILE)"

restore:
	test -f $(BACKUP_FILE)
	docker compose exec -T db psql -U appuser -d appdb < $(BACKUP_FILE)
	@echo "복구 완료: $(BACKUP_FILE)"

reset:
	docker compose down -v
	docker compose up -d --build

clean:
	docker compose down
