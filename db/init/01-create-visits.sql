-- db/init/01-create-visits.sql
-- visits 테이블 생성을 app/server.js에서 DB 초기화 SQL로 분리
-- created_at은 시간대 처리를 위해 TIMESTAMPTZ 사용

CREATE TABLE IF NOT EXISTS visits (
  id SERIAL PRIMARY KEY,
  created_at TIMESTAMPTZ DEFAULT now()
);
