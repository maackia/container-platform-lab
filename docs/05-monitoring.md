# Prometheus와 Grafana 모니터링

## 1. 구성 목적

애플리케이션이 실행 중이라는 사실만 확인하는 것을 넘어, 요청 수·DB 쿼리·메모리 사용량을 시간 흐름에 따라 관찰하기 위해 Prometheus와 Grafana를 추가했습니다.

```text
Node.js /metrics
-> Prometheus scrape
-> Grafana query
-> Dashboard
```

Prometheus는 메트릭을 주기적으로 수집하고 저장하며, Grafana는 PromQL로 저장된 시계열 데이터를 조회해 대시보드로 표시합니다.

## 2. 전체 구조

```text
Client
  |
  v
nginx:80
  |
  v
app:3000 ------> db:5432
  |
  | /metrics
  v
prometheus:9090
  |
  v
grafana:3000
```

Compose 내부에서는 서비스 이름이 DNS 이름으로 동작합니다.

- nginx -> `app:3000`
- app -> `db:5432`
- Prometheus -> `app:3000/metrics`
- Grafana -> `prometheus:9090`

따라서 컨테이너 사이의 주소에는 `localhost`가 아니라 Compose 서비스 이름을 사용합니다.

## 3. 애플리케이션 메트릭

Node.js 앱은 `prom-client`를 사용하며, `/metrics`에서 Prometheus 형식으로 메트릭을 노출합니다.

### 기본 메트릭

`collectDefaultMetrics()`로 Node.js 프로세스의 기본 메트릭을 수집합니다.

예:

- `process_resident_memory_bytes`: 프로세스의 resident memory
- `nodejs_heap_size_used_bytes`: Node.js heap 사용량
- `nodejs_eventloop_lag_seconds`: event loop 지연

### 사용자 정의 메트릭

```text
app_http_requests_total
```

HTTP 요청 수를 누적하는 Counter입니다.

라벨:

- `method`
- `route`
- `status_code`

```text
app_db_queries_total
```

DB 쿼리 실행 수를 누적하는 Counter입니다.

라벨:

- `operation`
- `status`

메트릭은 해당 코드 경로가 한 번 이상 실행된 뒤 나타날 수 있습니다. 예를 들어 DB 메트릭을 확인하기 전에는 먼저 애플리케이션 요청을 발생시킵니다.

```bash
curl http://localhost:8080/
curl -s http://localhost:8080/metrics | grep app_db_queries_total
```

## 4. Prometheus 설정

설정 파일:

```text
monitoring/prometheus/prometheus.yml
```

현재 설정은 5초마다 Node.js 앱의 `/metrics`를 수집합니다.

```yaml
global:
  scrape_interval: 5s

scrape_configs:
  - job_name: "node_app"
    metrics_path: /metrics
    static_configs:
      - targets:
          - "app:3000"
```

`app:3000`의 `app`은 Compose 서비스 이름입니다. Prometheus 컨테이너에서 `localhost:3000`은 Prometheus 자신을 가리키므로 사용할 수 없습니다.

### 수집 상태 확인

```bash
curl http://localhost:9090/-/ready
curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool
```

Prometheus 웹 화면의 Target health에서 `node_app`이 `UP`이면 정상입니다.

## 5. Grafana 설정

Grafana는 환경변수로 관리자 계정을 받고, named volume에 내부 데이터를 저장합니다.

```text
GRAFANA_PORT=3001
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=change-me
```

실제 비밀번호는 로컬 `.env`에서 변경하고, `.env`는 Git에 포함하지 않습니다.

Grafana 준비 상태:

```bash
curl http://localhost:3001/api/health
```

응답의 `"database": "ok"`를 확인합니다.

## 6. 데이터소스 provisioning

설정 파일:

```text
monitoring/grafana/provisioning/datasources/prometheus.yml
```

```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
```

Grafana 시작 시 Prometheus 데이터소스를 자동으로 등록합니다. `editable: false`이므로 웹 UI보다 Git의 설정 파일을 기준으로 관리합니다.

## 7. 대시보드 provisioning

관련 파일:

```text
monitoring/grafana/provisioning/dashboards/dashboards.yml
monitoring/grafana/dashboards/container-platform-lab.json
```

provider 설정은 Grafana가 대시보드 JSON을 읽을 디렉터리를 지정합니다. Compose에서는 해당 디렉터리를 읽기 전용으로 마운트합니다.

```text
./monitoring/grafana/dashboards
-> /var/lib/grafana/dashboards:ro
```

대시보드 UID는 `container-platform-lab`이며 기본 접속 주소는 다음과 같습니다.

```text
http://localhost:3001/d/container-platform-lab
```

대시보드 JSON은 Grafana가 읽는 실행 파일입니다. JSON에는 주석 문법이 없으므로, 학습용 설명은 별도의 JSONC 파일로 분리했습니다.

```text
docs/examples/container-platform-lab-dashboard.jsonc
```

## 8. 대시보드 패널

현재 대시보드는 다음 항목을 표시합니다.

| 패널 | PromQL | 의미 |
| --- | --- | --- |
| Application Status | `up{job="node_app"}` | Prometheus가 앱 메트릭을 수집할 수 있는지 확인 |
| HTTP Request Rate | `sum by (route) (rate(app_http_requests_total[1m]))` | route별 초당 요청률 |
| HTTP Responses by Status | `sum by (status_code) (rate(app_http_requests_total[1m]))` | HTTP 상태 코드별 응답률 |
| Database Queries in Last 5 Minutes | `sum by (operation, status) (increase(app_db_queries_total[5m]))` | 최근 5분 DB 쿼리 증가량 |
| Application Memory Usage | process / Node.js 기본 메트릭 | resident memory와 heap 사용량 |

대시보드는 5초마다 새로고침하며, 기본 시간 범위는 최근 15분입니다.

## 9. 실행 및 확인 방법

전체 실행:

```bash
make up
make ps
```

접속 주소:

```text
Application: http://localhost:8080
Prometheus:  http://localhost:9090
Grafana:     http://localhost:3001
```

테스트 트래픽 생성:

```bash
for i in $(seq 1 20); do
  curl -s http://localhost:8080/ > /dev/null
  sleep 1
done
```

Prometheus에서 확인할 기본 PromQL:

```promql
up
```

```promql
app_http_requests_total
```

```promql
app_db_queries_total
```

```promql
rate(app_http_requests_total{route="/"}[1m])
```

## 10. 문제 해결

### 메트릭 이름을 셸에서 실행한 경우

`app_db_queries_total`은 터미널 명령이 아니라 PromQL 메트릭 이름입니다. Prometheus 또는 Grafana 쿼리 입력란에서 실행해야 합니다.

터미널에서는 API를 사용합니다.

```bash
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=app_db_queries_total' \
  | python3 -m json.tool
```

### 앱에는 메트릭이 있지만 Prometheus 결과가 비어 있는 경우

먼저 앱의 `/metrics`를 확인합니다.

```bash
curl -s http://localhost:8080/metrics | grep app_http_requests_total
```

그다음 Prometheus target 상태와 마지막 오류를 확인합니다.

```bash
curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool
docker compose logs prometheus
```

### Grafana에 데이터가 바로 보이지 않는 경우

Prometheus의 scrape 주기는 5초이므로 새 메트릭이 수집될 때까지 잠시 기다린 뒤 새로고침합니다. 또한 대시보드의 시간 범위가 최근 데이터를 포함하는지 확인합니다.

### Grafana provisioning 오류가 발생한 경우

```bash
docker compose logs grafana | grep -iE "provision|dashboard|error"
```

다음 항목을 확인합니다.

- 데이터소스 UID가 `prometheus`로 일치하는지
- Grafana에서 Prometheus URL이 `http://prometheus:9090`인지
- 대시보드 JSON 문법이 올바른지
- provisioning 및 dashboard 디렉터리가 올바르게 마운트됐는지

JSON 문법 검사:

```bash
python3 -m json.tool monitoring/grafana/dashboards/container-platform-lab.json > /dev/null
```

Compose 설정 검사:

```bash
docker compose config > /dev/null
```
