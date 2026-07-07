-- db/init/01-create-visit.sql
-- visits 테이블 생성을 app/server.js 에서 DB 초기화 SQL로 분리

CREATE TABLE IF NOT EXISTS visits (
  id SERIAL PRIMARY KEY,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
