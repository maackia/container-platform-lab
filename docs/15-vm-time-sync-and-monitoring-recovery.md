# VM 시간 동기화와 모니터링 복구

이 문서는 Mac이 잠들거나 UTM Ubuntu VM이 일시 정지된 뒤 발생할 수 있는 시간 드리프트, Prometheus `No data`, Grafana `no available server`를 구분하고 복구하는 절차를 정리한다.

```text
Mac 절전 또는 VM 일시 정지
→ Ubuntu 시계가 실제 시간보다 느려짐
→ Prometheus 최신 표본의 시간축 불일치
→ Grafana 패널 No data

VM·K3s 재개
→ Pod sandbox와 컨테이너 재생성
→ Grafana 준비 전 Service endpoint 부족
→ no available server 또는 HTTP 503
```

두 증상이 같은 시점에 나타날 수 있지만, 시간 문제와 Grafana 준비 상태는 각각 확인해야 한다.

## 1. 시간대와 시간 드리프트 구분

Mac이 `Asia/Seoul`, Ubuntu가 `Etc/UTC`로 표시되는 것은 정상이다. 시간대가 달라도 같은 순간을 가리키면 문제가 없다.

```text
KST 13:30
= UTC 04:30
```

문제가 되는 것은 timezone 이름이 아니라 브라우저와 Prometheus 서버의 절대 시간이 실제로 몇 분 이상 어긋나는 상황이다. Prometheus UI는 이때 다음 경고를 표시한다.

```text
Server time is out of sync
Detected a time difference ... between your browser and the server
```

최신 5분을 조회해도 VM의 표본이 브라우저 기준 과거 또는 미래에 위치하므로 쿼리가 비어 보일 수 있다.

## 2. Ubuntu 시간 상태 확인과 복구

현재 상태를 확인한다.

```bash
timedatectl status
date -u
```

정상 상태의 핵심 항목은 다음 두 개다.

```text
System clock synchronized: yes
NTP service: active
```

NTP를 활성화하고 동기화 서비스를 다시 시작한다.

```bash
sudo timedatectl set-ntp true
sudo systemctl restart systemd-timesyncd
```

다시 확인한다.

```bash
date -u
timedatectl status
systemctl is-active systemd-timesyncd
```

`active`이고 UTC 시각이 현재 시각과 맞으면 Prometheus와 Grafana를 새로고침한다. 이미 잘못된 시간으로 저장된 과거 표본을 지우는 작업은 필요하지 않다. 새 scrape가 올바른 시각으로 들어오면 최신 범위가 다시 채워진다.

## 3. Mac 절전 예방

실습 중 Mac의 유휴 절전으로 VM이 멈추는 것을 줄이려면 Mac 터미널에서 다음 명령을 실행한 상태로 둔다.

```bash
caffeinate -i
```

`-i`는 사용자가 유휴 상태라는 이유로 시스템이 잠드는 것을 막는다. 명령이 실행되는 동안 터미널이 그대로 대기하는 것이 정상이며, 실습이 끝나면 해당 터미널에서 `Control+C`로 종료한다.

```text
caffeinate -i 실행 중
→ Mac 유휴 절전 억제
→ UTM VM 일시 정지 가능성 감소

Control+C
→ caffeinate 종료
→ 기존 절전 정책으로 복귀
```

노트북 덮개를 닫거나 사용자가 직접 잠자기를 선택하는 상황까지 모든 절전을 보장해서 막는 용도는 아니다. 장시간 자리를 비울 때는 진행 중인 부하 테스트와 변경 사항을 먼저 종료·저장한다.

## 4. K3s와 모니터링 Pod 상태 확인

VM 재개 또는 재부팅 직후에는 먼저 전체 모니터링 Pod의 준비 상태를 확인한다.

```bash
kubectl get pods -n monitoring -o wide
```

Grafana Pod는 Grafana 본체와 dashboard·datasource sidecar를 포함하므로 정상 상태가 `3/3 Running`이다.

```text
monitoring-grafana-...   3/3   Running
```

`2/3 Running`은 Pod 자체는 실행 중이지만 컨테이너 하나가 readiness를 통과하지 못했다는 뜻이다. `AGE`는 리소스 또는 Pod가 생성된 뒤의 시간이지 현재 컨테이너가 마지막으로 시작된 뒤의 시간과 항상 같지는 않다.

컨테이너별 상태와 마지막 종료 원인을 확인한다.

```bash
GRAFANA_POD="$(kubectl get pod \
  -n monitoring \
  -l app.kubernetes.io/name=grafana \
  -o jsonpath='{.items[0].metadata.name}')"

kubectl get pod \
  -n monitoring \
  "$GRAFANA_POD" \
  -o json \
  | jq '.status.containerStatuses[] |
    {
      name,
      ready,
      restartCount,
      state,
      lastState
    }'
```

## 5. `no available server` 진단

Traefik의 `no available server`는 Ingress가 가리키는 Service 뒤에 현재 요청을 받을 준비가 된 endpoint가 없을 때 주로 나타난다.

다음 순서로 범위를 좁힌다.

```bash
kubectl get deployment monitoring-grafana -n monitoring

kubectl get service monitoring-grafana -n monitoring

kubectl get endpointslice \
  -n monitoring \
  -l kubernetes.io/service-name=monitoring-grafana

kubectl describe pod -n monitoring "$GRAFANA_POD"
```

정상 복구 기준은 다음과 같다.

```text
Deployment AVAILABLE = 1
Grafana Pod READY = 3/3
EndpointSlice에 Grafana Pod IP 존재
/api/health 응답 성공
```

```bash
curl --noproxy '*' -fsS \
  http://grafana.platform.local:8081/api/health
```

## 6. Grafana 로그 확인

현재 컨테이너의 최근 로그를 확인한다.

```bash
kubectl logs \
  -n monitoring \
  "$GRAFANA_POD" \
  -c grafana \
  --since=30m \
  --timestamps \
  --tail=500
```

컨테이너가 재시작됐다면 직전 컨테이너의 로그도 확인한다.

```bash
kubectl logs \
  -n monitoring \
  "$GRAFANA_POD" \
  -c grafana \
  --previous \
  --timestamps \
  --tail=500
```

이벤트는 probe 실패와 Pod sandbox 재생성 시점을 보여준다.

```bash
kubectl get events \
  -n monitoring \
  --sort-by=.lastTimestamp
```

또는 특정 Pod의 이벤트만 본다.

```bash
kubectl describe pod -n monitoring "$GRAFANA_POD"
```

## 7. VM 재개 직후 흔한 로그

VM이 멈췄다가 재개되거나 재부팅된 직후에는 다음 이벤트가 일시적으로 발생할 수 있다.

```text
Readiness probe failed: connection refused
Readiness probe failed: context deadline exceeded
Liveness probe failed: HTTP 503
Pod sandbox changed
```

Grafana 로그에서는 내장 SQLite가 잠시 바쁜 상태도 관찰될 수 있다.

```text
database is locked (SQLITE_BUSY)
context deadline exceeded
```

Grafana가 초기화되는 동안 probe가 실패했다가 `3/3 Running`과 정상 health 응답으로 회복했다면 VM 재개 과정의 일시적인 현상으로 볼 수 있다. 과거 이벤트의 `Warning`은 상태가 회복돼도 바로 사라지지 않으므로 현재 `READY`, 최근 로그와 health 응답을 함께 판단한다.

## 8. 기다릴 때와 개입할 때

다음 조건이면 우선 짧게 기다리며 상태 변화를 관찰한다.

```text
Pod가 Running이고 restartCount가 더 증가하지 않음
probe 실패 간격이 줄어듦
로그에 초기화 진행이 보임
몇 분 안에 3/3 Ready로 전환됨
```

다음 조건이 계속되면 Grafana Deployment만 안전하게 재시작한다.

```text
3/3 Ready로 회복하지 않음
readiness·liveness 실패가 계속 증가
/api/health가 계속 503 또는 timeout
SQLite busy와 timeout이 장시간 반복
```

```bash
kubectl rollout restart \
  deployment/monitoring-grafana \
  -n monitoring

kubectl rollout status \
  deployment/monitoring-grafana \
  -n monitoring \
  --timeout=10m
```

이 작업은 Deployment가 Grafana Pod를 새로 만들도록 요청하며 Grafana PVC를 삭제하지 않는다. 데이터 파일이나 PVC 삭제는 복구 수단으로 바로 사용하지 않는다. 문제가 지속되면 PVC 상태와 노드 디스크·I/O를 확인하고, 데이터를 변경하기 전에 백업 계획을 세운다.

## 9. Prometheus `No data` 진단 순서

대시보드의 모든 패널이 동시에 `No data`라면 다음 순서로 확인한다.

```text
1. Prometheus UI의 time out of sync 경고 확인
2. Ubuntu timedatectl과 date -u 확인
3. Prometheus Pod와 /-/ready 확인
4. app target의 up 메트릭 확인
5. 원본 메트릭 확인
6. Recording Rule 확인
7. Grafana datasource와 패널 쿼리 확인
```

```bash
kubectl get pods -n monitoring

curl --noproxy '*' -fsS \
  http://prometheus.platform.local:8081/-/ready
```

```promql
up{namespace="platform-lab", job="app"}
```

```promql
app_http_requests_total{namespace="platform-lab", job="app"}
```

원본 메트릭까지 없다면 ServiceMonitor와 target 문제를 먼저 해결한다. 원본은 있고 Recording Rule만 없다면 Rule health와 최근 사용자 트래픽을 확인한다. Prometheus에는 값이 있는데 Grafana만 비어 있다면 datasource와 패널 시간 범위를 확인한다.

## 10. 재개 후 점검 체크리스트

```bash
timedatectl status
systemctl is-active systemd-timesyncd

kubectl get nodes
kubectl get pods -A

curl --noproxy '*' -fsS \
  http://prometheus.platform.local:8081/-/ready

curl --noproxy '*' -fsS \
  http://grafana.platform.local:8081/api/health

curl --noproxy '*' -fsS \
  http://alertmanager.platform.local:8081/-/ready
```

마지막으로 짧은 정상 트래픽을 보내 최신 표본이 들어오는지 확인한다.

```bash
make load-test-smoke
make load-test-baseline
```

```text
시간 동기화 정상
→ K3s Node Ready
→ 모니터링 Pod Ready
→ 각 서비스 health 정상
→ Prometheus target UP
→ Grafana 최신 패널 표시
```
