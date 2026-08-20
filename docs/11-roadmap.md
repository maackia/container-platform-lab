# 학습 로드맵과 다음 단계

이 문서는 `container-platform-lab`에서 완료한 범위와 앞으로 확장할 학습 주제를 한눈에 연결합니다. 로드맵의 순서는 반드시 지켜야 하는 커리큘럼이 아니라, 현재까지 쌓은 구성 위에 다음 개념을 자연스럽게 얹기 위한 권장 흐름입니다.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./assets/roadmap-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="./assets/roadmap-light.svg">
  <img src="./assets/roadmap-light.svg" width="100%" alt="Container Platform Lab의 여덟 단계 학습 로드맵">
</picture>

## 현재 위치

```text
컨테이너 기초
→ CI/CD와 이미지 배포
→ K3s 애플리케이션 플랫폼
→ 관측성·경고·알림 운영
→ 신뢰성 엔지니어링  ← 진행 중
```

현재까지 애플리케이션을 컨테이너로 실행하는 단계에서 시작해 Kubernetes 배포, 메트릭 수집, 대시보드, 경고, Discord 통지, Silence와 Inhibition 검증까지 완료했습니다. k6로 정상·지연·오류 트래픽을 반복 재현하고 경고와 복구 알림까지 확인했으며, 다음에는 이 결과를 Recording Rule과 SLO로 연결합니다.

## 1. Container Foundation — 완료

- nginx, Node.js, PostgreSQL 3-tier 구성
- Dockerfile과 Docker Compose 기반 실행
- healthcheck, 시작 순서, 네트워크, named volume
- PostgreSQL 초기화와 백업·복구

이 단계에서는 애플리케이션을 이미지와 컨테이너로 나누고, 여러 서비스를 하나의 로컬 스택으로 운영하는 흐름을 익혔습니다.

## 2. Delivery Pipeline — 완료

- GitHub Actions 문법·빌드·통합 테스트
- readiness 재시도와 실패 로그 수집
- GHCR `latest`, SHA, SemVer 태그 게시
- `linux/amd64`, `linux/arm64` 멀티 아키텍처 이미지
- 버전 고정 배포와 SHA 롤백

이 단계에서는 소스 변경을 검증된 이미지로 만들고, 어떤 버전을 배포했는지 추적하고 되돌릴 수 있도록 구성했습니다.

## 3. K3s Platform — 완료

- Namespace, Deployment, Service, ConfigMap, Secret
- StatefulSet와 local-path PVC
- startup, readiness, liveness probe
- Traefik Ingress와 로컬 호스트 라우팅
- 데모 애플리케이션과 Next.js 블로그 배포
- 블로그 `latest` 이미지 rollout 자동화

이 단계에서는 Compose의 서비스를 Kubernetes 리소스로 분해하고 선언형 배포와 복구 동작을 확인했습니다.

## 4. Observability and Alerting — 완료

- Helm과 `kube-prometheus-stack`
- ServiceMonitor 기반 메트릭 target 자동 발견
- Counter와 Histogram 기반 RED 메트릭
- Grafana 대시보드 ConfigMap provisioning
- replica, 오류율, p95 응답 지연 PrometheusRule
- AlertmanagerConfig와 Discord FIRING·RESOLVED 알림
- 유지보수 Silence와 critical → warning Inhibition

이 단계에서는 단순히 대시보드를 보는 것을 넘어, 이상 상태를 탐지하고 필요한 알림만 전달하는 운영 피드백 루프를 완성했습니다.

## 5. Reliability Engineering — 진행 중

다음 작업 묶음의 목표는 현재 경고가 우연히 동작하는 수준을 넘어, 동일한 조건을 반복해서 만들고 결과를 수치로 검증하는 것입니다.

1. 완료 — k6로 smoke·baseline·지연·오류율 시나리오를 스크립트화했습니다.
2. 완료 — Makefile 한 명령으로 시나리오를 실행하고 CI에서 스크립트와 smoke test를 검증합니다.
3. 완료 — p95 지연과 HTTP 5xx 경고의 FIRING·RESOLVED Discord 알림을 반복 검증했습니다.
4. 다음 — 자주 사용하는 PromQL을 Recording Rule로 계산해 대시보드와 경고에서 재사용합니다.
5. 다음 — 가용성·오류율·지연 시간에 대한 SLI와 SLO를 정의합니다.
6. 다음 — Error Budget 소진 속도를 대시보드와 경고로 확인합니다.

완료 기준은 다음과 같습니다.

```text
한 명령으로 부하 시나리오 실행
→ Prometheus에서 Recording Rule 확인
→ Grafana에서 SLO와 Error Budget 확인
→ 의도한 경고만 Discord로 전달
→ 부하 종료 후 RESOLVED 확인
```

## 6. GitOps — 계획

- Argo CD 설치와 애플리케이션 등록
- Git 저장소를 클러스터 desired state의 기준으로 사용
- 수동 `kubectl apply`와 실제 상태의 drift 확인
- 자동 동기화, 배포 이력, 롤백 실습

## 7. Platform Hardening — 계획

- External Secrets 또는 SOPS 기반 Secret 관리
- cert-manager와 TLS 인증서 자동화
- 이미지 취약점 스캔과 서명
- NetworkPolicy와 최소 권한 RBAC
- 백업·복구 절차의 정기 검증

## 8. Infrastructure Scale — 장기 확장

- Raspberry Pi 또는 미니 PC로 워크로드 이전
- 멀티 노드 Kubernetes와 장애 복구
- Terraform과 Ansible 기반 인프라 자동화
- AWS EKS로 관리형 Kubernetes 비교
- Kafka와 Flink를 통한 스트리밍 데이터 플랫폼 확장

## 로드맵 갱신 원칙

- 완료 여부는 파일 추가가 아니라 실제 실행과 검증 결과를 기준으로 판단합니다.
- 새 단계를 시작하기 전에 이전 단계의 README와 상세 문서를 정리합니다.
- 버전이 있는 도구는 적용 시점의 공식 문서와 권장 버전을 다시 확인합니다.
- 민감한 Secret 값과 개인 환경 정보는 로드맵이나 저장소에 기록하지 않습니다.
