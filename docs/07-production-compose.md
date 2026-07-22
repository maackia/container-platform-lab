# 배포용 Compose와 버전 롤백

## 1. 구성 목적

개발 환경에서는 app/Dockerfile로 이미지를 직접 빌드하고, 배포 환경에서는 CI가 GHCR에 게시한 이미지를 사용하도록 Compose 구성을 분리했습니다.

```text
compose.yaml
= 로컬 개발 및 기본 실행

compose.prod.yaml
= GHCR 이미지 기반 배포 override
```

기본 Compose 파일을 유지하면서 배포 시 필요한 app 설정만 덮어씁니다.

## 2. 배포용 Compose 설정

compose.prod.yaml:

```yaml
services:
  app:
    image: ghcr.io/maackia/container-platform-lab-app:${APP_IMAGE_TAG:-latest}
    build: null
```

- image: GHCR에서 받을 애플리케이션 이미지
- APP_IMAGE_TAG: 배포할 이미지 버전
- latest: 변수를 생략했을 때의 기본 태그
- build: null: 기본 compose.yaml의 로컬 build 설정 제거

최종 설정 확인:

```bash
docker compose \
  -f compose.yaml \
  -f compose.prod.yaml \
  config
```

## 3. 기본 배포

.env를 준비한 뒤 GHCR 이미지를 받습니다.

```bash
cp .env.example .env

docker compose \
  -f compose.yaml \
  -f compose.prod.yaml \
  pull app
```

전체 스택 실행:

```bash
docker compose \
  -f compose.yaml \
  -f compose.prod.yaml \
  up -d
```

기본값은 latest입니다. 학습과 빠른 확인에는 편리하지만, 재현 가능한 배포에는 고정 태그를 권장합니다.

## 4. 특정 버전 배포

v0.1.0 Git tag로 게시된 이미지 태그는 0.1.0입니다.

```bash
APP_IMAGE_TAG=0.1.0 docker compose \
  -f compose.yaml \
  -f compose.prod.yaml \
  pull app
```

```bash
APP_IMAGE_TAG=0.1.0 docker compose \
  -f compose.yaml \
  -f compose.prod.yaml \
  up -d
```

실제 컨테이너 이미지 확인:

```bash
docker inspect \
  "$(APP_IMAGE_TAG=0.1.0 docker compose \
    -f compose.yaml \
    -f compose.prod.yaml \
    ps -q app)" \
  --format '{{.Config.Image}}'
```

정상 결과:

```text
ghcr.io/maackia/container-platform-lab-app:0.1.0
```

## 5. 서비스 검증

```bash
curl -fsS http://localhost:8080/health
curl -fsS http://localhost:8080/
curl -fsS http://localhost:9090/-/ready
curl -fsS http://localhost:3001/api/health
```

Prometheus가 배포된 앱을 수집하는지 확인합니다.

```bash
curl -fsS \
  'http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22node_app%22%7D'
```

값이 "1"이면 정상입니다.

## 6. SHA 태그 롤백

SHA 태그는 특정 Git 커밋으로 만든 불변 이미지를 가리킵니다.

예:

```text
sha-75ab2e9
```

먼저 해당 이미지가 현재 환경의 아키텍처를 지원하는지 확인합니다.

```bash
docker buildx imagetools inspect \
  ghcr.io/maackia/container-platform-lab-app:sha-75ab2e9
```

이미지 pull:

```bash
APP_IMAGE_TAG=sha-75ab2e9 docker compose \
  -f compose.yaml \
  -f compose.prod.yaml \
  pull app
```

app 컨테이너만 교체:

```bash
APP_IMAGE_TAG=sha-75ab2e9 docker compose \
  -f compose.yaml \
  -f compose.prod.yaml \
  up -d --no-deps --force-recreate app
```

- --no-deps: DB, nginx, Prometheus, Grafana를 재시작하지 않음
- --force-recreate: 새 이미지 태그로 app 컨테이너를 다시 생성

적용 이미지와 서비스 상태를 다시 확인합니다.

## 7. 정식 버전으로 복귀

롤백 검증 후 0.1.0으로 복귀합니다.

```bash
APP_IMAGE_TAG=0.1.0 docker compose \
  -f compose.yaml \
  -f compose.prod.yaml \
  up -d --no-deps --force-recreate app
```

최종 검증:

```bash
curl -fsS http://localhost:8080/health
```

검증한 흐름:

```text
0.1.0 배포
-> 이전 SHA 이미지 롤백
-> 서비스 정상 확인
-> 0.1.0 재배포
-> 서비스 정상 확인
```

## 8. latest와 고정 태그의 차이

| 방식 | 장점 | 주의점 |
| --- | --- | --- |
| latest | 가장 최신 main을 간단히 실행 | 같은 설정이 실행 시점마다 다른 이미지를 가리킬 수 있음 |
| 0.1.0 | 배포 버전을 재현 가능 | 새 버전은 명시적으로 선택해야 함 |
| sha-* | 정확한 소스 커밋 추적과 롤백 | 사람이 의미를 파악하기 어려울 수 있음 |

운영과 롤백에는 0.1.0 또는 sha-*처럼 변경되지 않는 태그를 사용합니다.

## 9. ARM64 배포 확인

M3 Mac의 Ubuntu ARM64 VM에서 별도 플랫폼 지정 없이 이미지를 pull했습니다.

```bash
docker pull ghcr.io/maackia/container-platform-lab-app:0.1.0
```

확인:

```bash
docker image inspect \
  ghcr.io/maackia/container-platform-lab-app:0.1.0 \
  --format '{{.Architecture}}/{{.Os}}'
```

정상 결과:

```text
arm64/linux
```

Docker는 multi-architecture manifest에서 현재 호스트에 맞는 이미지를 자동 선택합니다.

## 10. 배포 종료와 데이터 주의점

컨테이너와 네트워크만 제거하고 DB·Grafana volume을 유지합니다.

```bash
docker compose \
  -f compose.yaml \
  -f compose.prod.yaml \
  down
```

volume까지 지우는 다음 명령은 데이터 초기화가 필요한 경우에만 사용합니다.

```bash
docker compose \
  -f compose.yaml \
  -f compose.prod.yaml \
  down -v
```

## 11. 완료 기준

```text
compose.prod.yaml override 적용
GHCR 이미지 기반 전체 스택 실행
APP_IMAGE_TAG로 버전 선택
v0.1.0 고정 배포
SHA 태그 롤백
정식 버전 재배포
ARM64 이미지 실행
애플리케이션·Prometheus·Grafana 정상 확인
```
