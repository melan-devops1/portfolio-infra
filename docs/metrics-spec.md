# 지표 수집 기준 (Metrics Specification)

> portfolio-app의 운영 지표 수집·시각화·알림 표준.
>
> 본 문서는 면접/리뷰 시 "이 프로젝트는 어떤 지표를 어떤 임계치로 보는가?"라는 질문에 즉시 답할 수 있는 단일 기준 문서입니다.

- **버전**: 1.0
- **최초 작성**: 2026-05-03
- **관련 ADR**: ADR-0022 (Observability Metrics), ADR-0024 (EFK), ADR-0025 (Jaeger), ADR-0026 (AlertmanagerConfig matcherStrategy)
- **소스 코드**: `portfolio-manifests/monitoring/`

---

## 1. 모니터링 대상 서비스

| 서비스 | 포트 | 역할 | 분산 호출 |
|---|---|---|---|
| product-service | 8081 | 상품 CRUD | 다운스트림 없음 |
| order-service | 8082 | 주문 생성 | product → payment |
| payment-service | 8083 | 결제 모의 | 다운스트림 없음 (의도적 Chaos 포함) |

3개 서비스 모두 Spring Boot Actuator + Micrometer + Prometheus 포맷으로 메트릭 노출. ServiceMonitor CRD로 자동 수집 (interval=15s).

---

## 2. 수집 지표 카테고리

### 2.1 RED 메트릭 (Application Layer)

운영의 3축 표준 — **Rate, Errors, Duration**.

#### Rate (요청 처리율)

```promql
# 서비스별 요청 처리율 (req/s)
sum by(application) (
  rate(http_server_requests_seconds_count[5m])
)
```

- **목적**: 트래픽 패턴 + 부하 시점 식별
- **수집 주기**: 5분 평균 (`[5m]`)
- **시각화**: Grafana 시계열 패널, 서비스별 색 구분

#### Errors (5xx 에러율)

```promql
# 서비스별 5xx 비율 (PrometheusRule HighErrorRate와 동일)
(
  sum(rate(http_server_requests_seconds_count{
    application=~"product-service|order-service|payment-service",
    status=~"5.."
  }[5m])) by (application)
  /
  sum(rate(http_server_requests_seconds_count{
    application=~"product-service|order-service|payment-service"
  }[5m])) by (application)
)
```

- **임계치**: **5%** 초과 시 critical 알림 (PrometheusRule `HighErrorRate`)
- **`for` 지속 조건**: 2분간 임계치 초과 지속 시에만 발화 (false alert 방지)
- **참고**: payment-service의 Chaos 시뮬레이션은 `PaymentDeclinedException` → 422로 매핑되므로 5xx에는 포함되지 않음 (함정 #53). 진짜 인프라 사고만 5xx로 분류.

#### Duration (P99 응답 시간)

```promql
# P99 (PrometheusRule HighLatencyP99와 동일)
histogram_quantile(0.99,
  sum(rate(http_server_requests_seconds_bucket{
    application=~"product-service|order-service|payment-service"
  }[5m])) by (le, application)
)
```

- **임계치**: **2초** 초과 시 warning 알림 (PrometheusRule `HighLatencyP99`)
- **`for` 지속 조건**: 2분
- **참고**: payment-service의 Chaos는 100~2000ms 랜덤 지연으로 P99 임계치(2초)와 의도적으로 매핑됨

```promql
# P95 (시연용 대시보드 패널)
histogram_quantile(0.95,
  sum by(application, le) (
    rate(http_server_requests_seconds_bucket[5m])
  )
)
```

### 2.2 인프라 메트릭 (Infrastructure Layer)

#### Pod 가용성

```promql
# scrape 성공 여부 (1=UP, 0=DOWN)
up{application=~"product-service|order-service|payment-service"}

# 서비스별 살아있는 Pod 수
sum by(application) (
  up{application=~"product-service|order-service|payment-service"}
)
```

- **목적**: HPA scale-up/down 추이, Pod 재생성 감지
- **임계치**: 의존하는 알림은 별도 (PodCrashLoopBackOff, PodNotReady 참조)

#### Pod 수명 사이클

```promql
# CrashLoopBackOff (PrometheusRule PodCrashLoopBackOff와 동일)
kube_pod_container_status_waiting_reason{
  reason="CrashLoopBackOff",
  namespace="default"
} > 0

# 5분 이상 NotReady (PrometheusRule PodNotReady와 동일)
kube_pod_status_ready{condition="false", namespace="default"} == 1
```

- **임계치**: 즉시 발화 (CrashLoopBackOff 2분, NotReady 5분)

#### JVM 자원 (Spring Boot 메트릭)

```promql
# Heap 사용량
jvm_memory_used_bytes{
  application="product-service",
  area="heap"
}

# 사용률 (%)
(
  jvm_memory_used_bytes{area="heap"}
  /
  jvm_memory_max_bytes{area="heap"}
) * 100
```

- **목적**: 메모리 누수 / OOM 사전 감지

#### CPU/메모리 (kube-state-metrics)

```promql
# Pod별 CPU 사용률
sum by(pod) (
  rate(container_cpu_usage_seconds_total{
    namespace="default",
    pod=~"product-service.*|order-service.*|payment-service.*"
  }[5m])
)

# Pod별 메모리 사용량 (바이트)
sum by(pod) (
  container_memory_working_set_bytes{
    namespace="default",
    pod=~"product-service.*|order-service.*|payment-service.*"
  }
)
```

---

## 3. 알림 규칙 (PrometheusRule 정의)

`portfolio-manifests/monitoring/prometheus-rules.yaml`에 정의됨. label `release: kube-prometheus-stack`이 박혀있어야 prometheus-operator가 자동 인식 (함정 #57 정합).

| 알림명 | 임계치 | for | severity | 의도 |
|---|---|---|---|---|
| `HighErrorRate` | 5xx 비율 > 5% | 2m | critical | 진짜 인프라 사고 (Chaos 422 제외) |
| `HighLatencyP99` | P99 > 2초 | 2m | warning | Chaos 시뮬레이션과 매핑 |
| `PodCrashLoopBackOff` | reason=CrashLoopBackOff | 2m | critical | OOM, 부팅 실패 등 |
| `PodNotReady` | ready=false | 5m | warning | rollout 지연, readinessGate 실패 등 |

### 3.1 임계치 선정 근거

#### 5xx 5%
- **운영 표준**: SLA 99.9% 가용성 = 0.1% 에러율 — 5%는 그것의 50배라 명백한 사고 시점
- **payment-service Chaos**: 5% 결제 거절(422)과 의도적으로 임계치 매핑 → "5xx 임계치 5%"는 진짜 인프라 사고만 잡음

#### P99 2초
- **사용자 경험 한계**: 2초 초과 시 사용자가 "느리다"고 인지
- **Chaos 매핑**: payment-service의 `CHAOS_MAX_DELAY=2000` 환경변수와 정확히 매핑
- **시연 의도**: 정상 부하에선 P99 ~500ms, Chaos 활성화 시 P99 ~2s 도달

#### CrashLoopBackOff 2분 / NotReady 5분
- **CrashLoopBackOff 2분**: K8s exponential backoff 기반 재시작 약 5회 시도 시간
- **NotReady 5분**: rollout 정상 시간(부팅 30초 × 2 + readinessGate 대기) + 여유

---

## 4. 알림 라우팅 (AlertmanagerConfig)

`portfolio-manifests/monitoring/alertmanager-config.yaml`. `matcherStrategy=None` 명시 (ADR-0026, 함정 #57 청산).

| severity | Receiver | 채널 | 그룹핑 | 반복 간격 |
|---|---|---|---|---|
| critical | slack-critical | #ops-alert | groupWait 5s | 1h |
| warning | slack-warning | #ops-alert | groupWait 10s | 1h |
| (없음) | slack-default | #ops-alert | groupBy alertname,application | - |

운영 환경 진입 시 검토 (Phase 5+):
- critical에 이메일 receiver 추가 (현재 Slack only)
- 업무 시간 외 critical 에스컬레이션 (PagerDuty 등)

---

## 5. 메트릭 수집 흐름 검증

매 destroy/apply 사이클의 검증 명령:

```bash
# 1) ServiceMonitor 자동 감지 검증
kubectl get servicemonitors -n monitoring
# 3개 (product/order/payment-service) 보여야 정상

# 2) Prometheus가 실제 수집 중인지 — targets 확인
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s 'http://localhost:9090/api/v1/targets' | jq '.data.activeTargets[].labels.application' | sort -u
# product-service / order-service / payment-service 보여야 정상

# 3) PrometheusRule 자동 등록 검증
kubectl get prometheusrules -n monitoring
# portfolio-app-rules 보여야 정상

# 4) AlertmanagerConfig 등록 검증
kubectl get alertmanagerconfigs -n monitoring
# portfolio-alertmanager-config 보여야 정상

# 5) Alertmanager runtime config의 namespace prefix 검증 (함정 #57)
kubectl exec -n monitoring -it alertmanager-kube-prometheus-stack-alertmanager-0 \
  -c alertmanager -- wget -qO- http://localhost:9093/api/v2/status \
  | jq '.config.original' | grep -A 2 matchers
# matchers에 namespace prefix 없어야 정상 (matcherStrategy=None 적용 결과)
```

---

## 6. 시각화 표준

### 6.1 Grafana 대시보드

#### 자동 박제 (kube-prometheus-stack)
chart 설치 시 34개 자동 임포트. 자주 쓰는 것:
- `Kubernetes / Compute Resources / Pod` — Pod별 CPU/메모리 spike
- `Kubernetes / Compute Resources / Namespace (Pods)` — namespace 통합 뷰
- `Node Exporter / Nodes` — 노드 레벨

#### 도메인 비즈니스 대시보드 (작성 예정)
운영 통합 패널 (위 RED + 인프라 + 비즈니스 메트릭 결합):
- 패널 1: 서비스별 요청 처리율 (시계열)
- 패널 2: 5xx 에러율 (Threshold 5% 빨강)
- 패널 3: P99 응답 시간 (Threshold 2초 빨강)
- 패널 4: 주문 처리량 (`http_server_requests_seconds_count{uri="/api/orders",method="POST",status="201"}`의 rate)
- 패널 5: 결제 성공률 (`status="201" / total`)

### 6.2 Kibana data view

- **Index pattern**: `portfolio-*`
- **Timestamp field**: `@timestamp`
- **검증 필드**: `kubernetes.namespace_name`, `application`, `requestId`, `level`

---

## 7. 변경 이력

| 일자 | 변경 | 사유 |
|---|---|---|
| 2026-05-02 | matcherStrategy=None 명시 | 함정 #57, 알림 라우팅 사고 영구 청산 (ADR-0026) |
| 2026-05-02 | EFK 인덱스 패턴 `portfolio-*` 확정 | Fluent Bit values.yaml의 Logstash_Prefix 정합 (ADR-0024) |
| 2026-05-02 | OTEL exporter 분리 — traces only | metrics는 Prometheus, logs는 Fluent Bit (ADR-0025) |
| 2026-05-03 | 본 문서 최초 작성 | 지표 수집 기준 통합 |