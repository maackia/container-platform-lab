# 문서 목차

이 디렉터리는 `container-platform-lab`의 자세한 학습 기록과 운영 명령을 정리하는 공간입니다.

최상위 `README.md`는 프로젝트 소개와 빠른 실행 중심으로 유지하고, 상세 설명은 이곳에 분리합니다.

## 문서 목록

1. [프로젝트 구조와 아키텍처](./01-architecture.md)
2. [운영 명령과 점검 방법](./02-operations.md)
3. [데이터베이스 초기화와 시간대 정책](./03-database-init-and-timezone.md)
4. [PostgreSQL 백업과 복구](./04-backup-and-restore.md)
5. [Prometheus와 Grafana 모니터링](./05-monitoring.md)
6. [GitHub Actions CI와 GHCR 이미지 게시](./06-ci-cd.md)
7. [배포용 Compose와 버전 롤백](./07-production-compose.md)

## 참고 예제

- [주석이 포함된 Grafana 대시보드 JSONC](./examples/container-platform-lab-dashboard.jsonc)

## 정리 원칙

- README는 짧고 실행 중심으로 유지한다.
- docs는 학습 과정, 시행착오, 운영 개념을 자세히 기록한다.
- 개인적인 진행 로그와 더 긴 메모는 Notion에 보관한다.
- GitHub 문서는 포트폴리오 관점에서 다시 읽기 쉬운 형태로 정리한다.
