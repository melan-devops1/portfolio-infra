# Kibana SLA Compliance 대시보드

> 로그 분석 기반 SLA 준수 여부 시각화 가이드.
>
> 본 문서는 **수동 생성 단계**와 **가져오기 가능한 NDJSON saved object**를 함께 제공합니다.

- **버전**: 1.0
- **최초 작성**: 2026-05-03
- **관련 문서**: [sla.md](../sla.md), [metrics-spec.md](../metrics-spec.md)
- **NDJSON**: `sla-saved-objects.ndjson` (이 폴더)

---

## 1. 본 대시보드의 위치 — 정직한 한계 명시

### 1.1 Prometheus가 1차 source인 이유

[sla.md](../sla.md)의 SLA/SLO는 **Prometheus 메트릭 기반**으로 정의했습니다. 이유:

| 측정 항목 | 메트릭 (Prometheus) | 로그 (Kibana) |
|---|---|---|
| 전체 요청 수 | `http_server_requests_seconds_count` 정확 | access 로그 활성화 필요 |
| 5xx 응답 수 | `status=~"5.."` label 정확 | 동일 |
| 응답 시간 분포 | `histogram_quantile` 정확 | 별도 timer 로그 필요 |
| 가용성 % | rate 비율로 정확 계산 | 분모 부재 시 계산 불가 |

본 프로젝트의 portfolio-app은 **Spring Boot Actuator + Micrometer**로 메트릭이 정확하게 노출되므로 SLA 1차 계산은 **Prometheus가 정답**.

### 1.2 그럼 Kibana는 무슨 역할인가

로그 기반 시각화는 **메트릭이 잡지 못하는 컨텍스트**를 보강합니다:

- **에러 메시지 / stack trace** — 메트릭은 "5xx 발생"만 알려주고 "왜"는 모름
- **에러 분포** — exception 타입별 / requestId별 빈도
- **상관 분석** — 같은 requestId의 분산 호출 trace
- **인덱스 패턴 검색** — KQL로 임의 조건 자유 탐색
- **사고 회고** — Runbook의 진단 단계에서 활용

따라서 본 Kibana SLA 대시보드는 **"SLA 위반 사고 발생 시 진단을 빠르게 만드는 보조 도구"**로 정의합니다.

### 1.3 본 프로젝트 로그의 한계 (현재 상태)

`portfolio-app/src/main/resources/logback-spring.xml`의 prod 프로파일은 **애플리케이션 로그만 출력** — INFO/WARN/ERROR. HTTP 요청별 access 로그는 활성화되지 않음.

가능한 것 ✅:
- ERROR 빈도 추이
- 서비스별 ERROR 분포
- exception 클래스 분포
- WARN 레벨 사고 (Chaos 시뮬레이션 등)

직접 불가능한 것 ❌:
- "총 요청 수" (분모 부재)
- "API endpoint별 가용성"
- "사용자별 SLO 위반 수"

§5에서 access 로그 활성화 방법을 명시합니다.

---

## 2. 활용 가능한 로그 필드

logback-spring.xml의 LogstashEncoder가 출력하는 표준 필드:

| 필드 | 타입 | 예시 | 용도 |
|---|---|---|---|
| `@timestamp` | date | `2026-05-02T15:23:01.456Z` | 시간 기준 |
| `level` | keyword | `ERROR`, `WARN`, `INFO` | 심각도 분류 |
| `application` | keyword | `product-service` | 서비스 분류 |
| `message` | text | `Product not available: id=1` | 전문 검색 |
| `logger_name` | keyword | `c.p.o.s.OrderService` | 코드 위치 |
| `stack_trace` | text | (multiline) | exception 분석 |
| `thread_name` | keyword | `http-nio-8081-exec-3` | 동시성 분석 |
| `kubernetes.namespace_name` | keyword | `default` | (Fluent Bit kubernetes filter 추가) |
| `kubernetes.pod_name` | keyword | `product-service-abc` | (동일) |

OpenTelemetry Java Agent (ADR-0025)가 활성화된 경우 추가:
- `traceId`, `spanId` — Jaeger 연동 가능

---

## 3. SLA Compliance 대시보드 구성

### 3.1 패널 구조 (5개)

```
┌──────────────────────────────────┬───────────────────────────────────┐
│  Panel 1: ERROR 빈도 (시계열)     │  Panel 2: 서비스별 ERROR (도넛)   │
│  level:ERROR over time            │  application별 분포               │
├──────────────────────────────────┴───────────────────────────────────┤
│  Panel 3: Top Exception 클래스 (테이블)                              │
│  logger_name + message에서 추출                                       │
├──────────────────────────────────┬───────────────────────────────────┤
│  Panel 4: WARN/ERROR 비율 (KPI)   │  Panel 5: 최근 ERROR 로그 (목록)  │
│  level별 카운트 비율               │  Discover 임베드                  │
└──────────────────────────────────┴───────────────────────────────────┘
```

### 3.2 Panel 1 — ERROR 빈도 (시계열)
- **유형**: Line chart (Lens)
- **인덱스**: `portfolio-*`
- **Filter (KQL)**: `level: ERROR`
- **X축**: `@timestamp` (Date histogram, auto interval)
- **Y축**: Count of records
- **Break down**: `application` (서비스별 색 구분)

### 3.3 Panel 2 — 서비스별 ERROR 분포 (도넛)
- **유형**: Pie / Donut
- **Filter (KQL)**: `level: ERROR`
- **Slice by**: `application.keyword`
- **Metric**: Count of records

### 3.4 Panel 3 — Top Exception (테이블)
- **유형**: Data table
- **Filter (KQL)**: `level: ERROR AND stack_trace: *`
- **Rows**: `logger_name.keyword` (top 10)
- **Metrics**: Count of records

### 3.5 Panel 4 — WARN vs ERROR 비율 (KPI 또는 metric)
- **유형**: Metric
- **Filter (KQL)**: `level: (WARN OR ERROR)`
- **Metric**: Count of records (level별 break down)

### 3.6 Panel 5 — 최근 ERROR 로그
- **유형**: Saved Search 임베드
- **Saved Search**: `Recent Errors`
- **Filter (KQL)**: `level: ERROR`
- **Sort**: `@timestamp` desc
- **Columns**: `@timestamp`, `application`, `logger_name`, `message`

---

## 4. 수동 생성 단계 (Kibana 8.15 기준)

### 4.1 Data View 생성
1. Kibana 좌측 메뉴 → **Stack Management** → **Data Views**
2. **Create data view** 클릭
3. 입력:
   - **Name**: `portfolio`
   - **Index pattern**: `portfolio-*`
   - **Timestamp field**: `@timestamp`
4. **Save data view to Kibana** 클릭

### 4.2 Saved Search 생성 (Recent Errors)
1. 좌측 메뉴 → **Discover**
2. Data view: `portfolio` 선택
3. KQL 검색 창에 입력: `level: "ERROR"`
4. 우측 **Selected fields**에 추가: `@timestamp`, `application`, `logger_name`, `message`
5. 정렬: `@timestamp` desc
6. 우측 상단 **Save** 클릭 → 이름 `Recent Errors` 저장

### 4.3 Visualization 생성 (Lens 사용)
1. 좌측 메뉴 → **Visualize Library** → **Create visualization** → **Lens**
2. Data view: `portfolio` 선택
3. Panel 1~4를 §3 명세대로 차례로 생성, 각각 저장

### 4.4 Dashboard 조립
1. 좌측 메뉴 → **Dashboards** → **Create dashboard**
2. **Add from library**로 §4.2~4.3에서 저장한 5개 항목 추가
3. 패널 크기·위치 조정 (§3.1 레이아웃 기준)
4. 우측 상단 **Save** → 이름 `SLA Compliance` 저장

### 4.5 시간 범위 기본값
- 우측 상단 시간 선택 → **Last 24 hours** 또는 **Last 1 hour**
- 매 destroy/apply 사이클은 짧으므로 **Last 15 minutes**부터 시작 권장

---

## 5. NDJSON 가져오기 (빠른 구성)

§4.1 Data View와 §4.2 Saved Search를 즉시 가져오는 NDJSON 파일을 함께 제공합니다 (`sla-saved-objects.ndjson`).

### 5.1 가져오기 절차
1. Kibana → **Stack Management** → **Saved Objects**
2. 우측 상단 **Import** 클릭
3. `sla-saved-objects.ndjson` 파일 선택 → **Import**
4. 충돌 발생 시 **Overwrite all** 선택

### 5.2 가져오는 항목
- Data View: `portfolio` (`portfolio-*` 패턴)
- Saved Search × 4:
  - `Recent Errors` (level: ERROR)
  - `Service Errors - product` (application: product-service AND level: ERROR)
  - `Service Errors - order` (application: order-service AND level: ERROR)
  - `Chaos Decline Events` (application: payment-service AND PaymentDeclined*)

§4.3~4.4의 시각화·대시보드는 Lens 스키마 변동 가능성이 있어 NDJSON에 포함하지 않음. **Discover에서 saved search를 패널로 임베드**하면 NDJSON만으로도 기본 SLA 뷰 구성 가능.

---

## 6. 운영 환경 진화 — 전체 SLA 계산을 logs에서 가능하게 하기

### 6.1 Spring Boot CommonsRequestLoggingFilter 활성화

`portfolio-app/<service>/src/main/java/.../config/RequestLoggingConfig.java`:

```java
@Configuration
@Profile("prod")
public class RequestLoggingConfig {
    @Bean
    public CommonsRequestLoggingFilter requestLoggingFilter() {
        var filter = new CommonsRequestLoggingFilter();
        filter.setIncludeQueryString(true);
        filter.setIncludePayload(false);  // 민감 정보 누출 방지
        filter.setIncludeHeaders(false);
        filter.setIncludeClientInfo(true);
        filter.setMaxPayloadLength(1000);
        return filter;
    }
}
```

`application-prod.yaml`:
```yaml
logging:
  level:
    org.springframework.web.filter.CommonsRequestLoggingFilter: DEBUG
```

이 활성화 후 다음 필드 추가됨:
- `uri` — 요청 URI
- `method` — HTTP method
- `clientIp` — 호출자 IP
- (status는 별도 interceptor 필요)

### 6.2 더 정확한 access 로그 — Logback access logger

또는 별도 logger:

```xml
<!-- logback-spring.xml prod 프로파일 추가 -->
<logger name="ACCESS" level="INFO" additivity="false">
    <appender-ref ref="JSON_CONSOLE"/>
</logger>
```

별도 Filter에서 `LoggerFactory.getLogger("ACCESS")`로 모든 응답에 status 포함 로깅.

### 6.3 Access 로그 활성화 후 Kibana SLA 계산

```
가용성 % = (요청 수 - 5xx 수) / 요청 수 × 100

KQL:
  요청 분모: logger_name: "ACCESS"
  5xx 분자:  logger_name: "ACCESS" AND status >= 500
```

이 시점부터 Kibana에서 **로그 기반 SLA 직접 계산 가능**. Prometheus와 교차 검증으로 정확도 향상.

---

## 7. 변경 이력

| 일자 | 변경 | 사유 |
|---|---|---|
| 2026-05-03 | 본 가이드 최초 작성 | 심화 (3) 필수 항목 충족 |

---

## 8. 한마디로 정리

> "심화 요건의 'SLA 준수 여부 산출 Kibana 뷰'는 본 환경 한계를 정직하게 명시한 후 단계적으로 박제했습니다.
>
> 첫째 한계 명시. 현재 logback-spring.xml은 애플리케이션 로그(INFO/WARN/ERROR)만 출력해 'SLA 분모인 총 요청 수'를 logs에서 직접 셀 수 없습니다. 따라서 본 환경의 SLA 1차 source는 Prometheus 메트릭으로 정의(sla.md), Kibana는 'SLA 위반 사고 발생 시 진단을 빠르게 만드는 보조 도구'로 역할 정립했습니다.
>
> 둘째 가능한 시각화. 5패널 대시보드 — ERROR 빈도 시계열, 서비스별 ERROR 분포, Top Exception 테이블, WARN/ERROR KPI, 최근 ERROR 목록. NDJSON saved object로 즉시 가져오기 가능하도록 박제했습니다.
>
> 셋째 운영 진화 경로. CommonsRequestLoggingFilter 또는 별도 ACCESS logger 활성화 시 logs 기반 SLA 직접 계산 가능. 이 경우 Prometheus와 교차 검증으로 정확도 향상이 기대됩니다.
>
> 핵심은 '메트릭과 로그는 역할이 다르다'는 운영 원칙을 명확히 하고, 본 환경에서 가능한 만큼 SLA 가시성을 확보하면서 다음 단계의 진화 경로까지 함께 명시한 점입니다."