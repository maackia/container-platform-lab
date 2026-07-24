# GitHub Actions CI와 GHCR 이미지 게시

## 1. 구성 목적

로컬에서 수동으로 수행하던 문법 검사, Compose 검증, 이미지 빌드와 서비스 확인을 GitHub Actions로 자동화했습니다.

```text
Pull Request / main push
-> 정적 검증
-> Compose 이미지 빌드
-> 전체 스택 실행
-> 통합 테스트
-> 결과와 로그 확인
```

CI는 코드와 설정이 깨끗한 Runner에서도 재현되는지 확인하고, 게시 workflow는 main과 Git tag를 기준으로 배포 가능한 애플리케이션 이미지를 GHCR에 저장합니다.

## 2. Workflow 구성

```text
.github/workflows/
├── ci.yml
└── publish.yml
```

- ci.yml: push와 Pull Request에서 애플리케이션 및 전체 Compose 스택 검증
- publish.yml: main 또는 v*.*.* Git tag에서 GHCR 이미지 게시

두 workflow를 분리해 검증과 게시의 책임을 구분했습니다.

## 3. 기본 CI 검증

CI는 Ubuntu Runner와 Node.js 24를 사용합니다.

```text
actions/checkout
-> actions/setup-node
-> npm ci
-> node --check
-> docker compose config
-> docker compose build
```

주요 검사:

- package-lock.json 기준 의존성 재현 설치
- server.js 문법 검사
- .env.example을 이용한 환경변수 구성
- Compose YAML과 변수 치환 검증
- 애플리케이션 Docker 이미지 빌드

Runner는 실행마다 새로 만들어지므로 로컬 캐시나 남아 있는 파일에 의존하는 문제를 찾을 수 있습니다.

## 4. 컨테이너 통합 테스트

정적 검증 후 실제 Compose 스택을 실행합니다.

```text
docker compose up -d
-> application health
-> application response
-> Prometheus readiness
-> Prometheus target
-> Grafana health
```

확인 범위:

- nginx를 경유한 /health 응답
- nginx -> Node.js -> PostgreSQL 실제 요청
- Prometheus HTTP 준비 상태
- up{job="node_app"} 값이 1인지 확인
- Grafana /api/health의 database 값이 ok인지 확인

따라서 단순히 이미지를 빌드하는 데서 끝나지 않고 서비스 간 연결까지 자동으로 검증합니다.

## 5. Readiness 재시도 안정화

docker compose up -d의 성공은 컨테이너 프로세스가 시작되었다는 뜻이며, HTTP 서비스의 준비 완료를 보장하지 않습니다.

초기 CI에서는 시작 직후 한 번만 curl을 실행해 다음과 같은 간헐적 실패가 발생했습니다.

```text
connection refused
connection reset by peer
Prometheus query result: []
```

이를 해결하기 위해 애플리케이션, Prometheus target, Grafana를 최대 30회 재시도하도록 변경했습니다.

```text
최대 30회
-> 요청별 connect timeout 2초
-> 요청별 max time 5초
-> 실패 시 3초 대기
```

핵심 원칙:

```text
container started != service ready
```

Prometheus의 /-/ready와 app target 수집도 별도로 검사합니다. Prometheus API가 준비됐더라도 첫 scrape가 끝나기 전에는 target 시계열이 비어 있을 수 있기 때문입니다.

## 6. 실패 진단과 정리

검사 성공 여부와 관계없이 서비스 상태를 출력합니다.

```bash
docker compose ps
```

실패한 경우 전체 로그의 마지막 200줄을 출력합니다.

```bash
docker compose logs --no-color --tail=200
```

마지막 단계는 항상 실행됩니다.

```bash
docker compose down -v --remove-orphans
```

이를 통해 테스트 컨테이너, 네트워크, volume, orphan 컨테이너를 정리합니다.

## 7. GHCR 게시 Workflow

게시 대상:

```text
ghcr.io/maackia/container-platform-lab-app
```

publish.yml은 GitHub가 제공하는 GITHUB_TOKEN으로 GHCR에 로그인하며, packages: write 권한만 추가합니다.

```text
checkout
-> GHCR login
-> metadata 생성
-> QEMU
-> Buildx
-> build and push
```

GitHub Actions cache를 사용해 변경되지 않은 이미지 레이어를 재사용합니다.

## 8. 멀티 아키텍처 이미지

초기 이미지는 amd64만 포함해 M3 Mac의 arm64 환경에서 다음 오류가 발생했습니다.

```text
no matching manifest for linux/arm64/v8
```

QEMU와 Docker Buildx를 추가하고 두 플랫폼을 함께 게시하도록 수정했습니다.

```yaml
platforms: linux/amd64, linux/arm64
```

하나의 태그 아래에 두 아키텍처 manifest가 포함됩니다.

```text
image tag
├── linux/amd64
└── linux/arm64
```

확인:

```bash
docker buildx imagetools inspect \
  ghcr.io/maackia/container-platform-lab-app:0.1.0
```

M3 Mac에서 pull한 이미지 확인:

```bash
docker image inspect \
  ghcr.io/maackia/container-platform-lab-app:0.1.0 \
  --format '{{.Architecture}}/{{.Os}}'
```

정상 결과:

```text
arm64/linux
```

## 9. 이미지 태그 전략

게시 workflow는 목적에 따라 태그를 나눕니다.

| 태그 | 생성 시점 | 용도 |
| --- | --- | --- |
| latest | 기본 브랜치 push | main의 최신 이미지 |
| sha-* | main 또는 Git tag 게시 | 특정 Git 커밋 추적과 롤백 |
| 0.1.0 | v0.1.0 Git tag | 변경되지 않는 정식 버전 |
| 0.1 | v0.1.0 Git tag | minor 버전의 최신 patch |

SemVer 이미지는 다음 순서로 생성합니다.

```bash
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
```

Git tag는 v0.1.0이지만 컨테이너 이미지에는 0.1.0과 0.1 태그가 생성됩니다.

## 10. 브랜치와 PR 흐름

기능별 브랜치에서 작업하고 main에는 Pull Request로 반영했습니다.

```text
main 최신화
-> feature branch
-> commit / push
-> Pull Request
-> CI 통과
-> merge
-> main 동기화
```

예:

```bash
git switch main
git pull origin main
git switch -c feature/example

# 작업 후
git push -u origin feature/example
```

merge 후:

```bash
git switch main
git pull origin main
git branch -d feature/example
git fetch --prune
```

## 11. Kubernetes 매니페스트 검증

K3s 매니페스트가 추가된 뒤 `ci.yml`에 별도의 `validate-kubernetes` Job을 구성했습니다.

```text
Pull Request / main push
├── validate-kubernetes
│   └── Kubeconform
└── test
    └── Compose 통합 테스트
```

두 Job은 서로 독립적으로 실행되므로 Kubernetes 스키마 오류와 Compose 통합 테스트 실패를 구분할 수 있습니다.

Kubeconform은 검증한 `v0.8.0` 버전으로 고정했습니다.

```bash
docker run --rm \
  -v "$PWD:/work" \
  ghcr.io/yannh/kubeconform:v0.8.0 \
  -strict -summary /work/k8s
```

옵션의 의미:

```text
-strict
→ 스키마에 정의되지 않은 필드를 오류로 처리

-summary
→ 유효·오류·건너뜀 리소스 수를 요약
```

`latest` 태그는 실행 시점에 따라 도구 버전이 달라질 수 있다. CI에서는 확인한 버전을 명시해 재현성을 유지하고, 업그레이드할 때 릴리스와 기존 매니페스트 호환성을 다시 확인한다.

로컬에서는 실제 K3s API를 사용하는 서버 측 dry-run을 함께 실행한다.

```bash
kubectl apply --dry-run=server -f k8s/
```

Kubeconform은 빠른 정적 스키마 검사에 적합하고, 서버 측 dry-run은 현재 클러스터의 API와 admission 설정을 반영한다. 두 검사를 상호 보완적으로 사용한다.

## 12. 완료 기준

```text
Node.js 24 환경 통일
CI 정적 검증 성공
Compose 전체 통합 테스트 성공
readiness 재시도 안정화
GHCR 이미지 게시
amd64 / arm64 manifest 확인
latest / SHA / SemVer 태그 생성
v0.1.0 이미지 pull 검증
Kubeconform v0.8.0 Kubernetes 매니페스트 검증
```
