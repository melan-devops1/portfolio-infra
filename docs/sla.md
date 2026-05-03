# SLA / SLO 기준 (Service Level Agreement & Objectives)

> portfolio-app의 가용성·성능 보장 기준 + 측정 방법.

- **버전**: 1.0
- **최초 작성**: 2026-05-03
- **관련 문서**: [metrics-spec.md](./metrics-spec.md), [runbook/](./runbook/)

---

## 1. SLA / SLO / SLI 정의

### 용어
- **SLA (Service Level Agreement)**: 외부 약속 (계약 수준)
- **SLO (Service Level Objective)**: 내부 목표 (운영 기준)
- **SLI (Service Level Indicator)**: 실제 측정 지표

본 프로젝트는 외부 고객 없는 포트폴리오 환경이므로 SLO 중심으로 정의합니다. 운영 환경 진입 시 SLA로 승격 가능하도록 동일 형식 사용.

---

## 2. 핵심 SLO

### 2.1 가용성 — 월간 99.9%

| 항목 | 값 | 의미 |
|---|---|---|
| **SLO** | 월간 가용성 99.9% | 한 달 30일 기준 허용 다운타임 ≈ 43분 |
| **측정 단위** | API 요청 단위 | "요청이 성공 응답(2xx, 4xx) 받았는가" |
| **측정 기간** | 30일 rolling window |  |
| **에러 예산 (Error Budget)** | 0.1% = 한 달 ~43분 |  |

### 2.2 가용성 SLI 측정 공식

```promql
# 30일 가용성 (Rolling 30d)
(
  sum(rate(http_server_requests_seconds_count{
    application=~"product-service|order-service|payment-service",
    status!~"5.."
  }[30d]))
  /
  sum(rate(http_server_requests_seconds_count{
    application=~"product-service|order-service|payment-service"
  }[30d]))
) * 100
```

#### 분류
- **성공 (가용성 카운트 ✅)**: 2xx, 4xx (4xx는 클라이언트 에러로 서버는 정상)
- **실패 (가용성 카운트 ❌)**: 5xx (인프라/서버 사고)

#### Chaos 시뮬레이션은 가용성 카운트 안 됨
payment-service의 `PaymentDeclinedException`은 의도적 거절로 422 (4xx). 따라서 Chaos 5%는 **가용성에 영향 없음**. 진짜 인프라 사고(5xx)만 가용성 차감 (함정 #53).

### 2.3 성능 — P99 < 2초

| 항목 | 값 | 의미 |
|---|---|---|
| **SLO** | P99 응답 시간 < 2초 | 99% 요청이 2초 내 응답 |
| **측정 기간** | 5분 rolling window |  |
| **알림 임계치** | P99 > 2s 지속 2분 | warning Slack 발화 |

```promql
# P99 측정
histogram_quantile(0.99,
  sum(rate(http_server_requests_seconds_bucket{
    application=~"product-service|order-service|payment-service"
  }[5m])) by (le, application)
)
```

### 2.4 5xx 에러율 — < 5%

| 항목 | 값 | 의미 |
|---|---|---|
| **SLO** | 5xx 비율 < 5% | 진짜 인프라 사고 임계치 |
| **측정 기간** | 5분 rolling window |  |
| **알림 임계치** | > 5% 지속 2분 | critical Slack 발화 |

5xx 5%는 SLO보다 50배 큰 alert 임계치 (가용성 SLO 99.9% = 5xx 0.1%). 즉시 사고로 간주.

```promql
# 5xx 비율
(
  sum(rate(http_server_requests_seconds_count{status=~"5.."}[5m])) by (application)
  /
  sum(rate(http_server_requests_seconds_count[5m])) by (application)
) * 100
```

---

## 3. 임계치 선정 근거

### 3.1 99.9% 선택 이유

| 가용성 | 월간 다운타임 허용 | 적합 환경 |
|---|---|---|
| 99% | ~7시간 | 사내 도구 |
| **99.9%** | **~43분** | **소규모 SaaS / 본 프로젝트** |
| 99.99% | ~4분 | 중대형 운영 |
| 99.999% | ~26초 | 통신/금융 인프라 |

본 프로젝트는 1인 dev 환경이지만 운영 표준의 "엔트리 레벨 SLO"인 99.9%를 채택해 면접 대화에서 "어떤 SLO에서 운영해본 경험 있나요?" 질문에 명확히 답변.

### 3.2 P99 2초 선택 이유

#### 사용자 경험 기반
- **100ms**: 즉시 (사용자가 "빠르다" 인지)
- **1s**: 흐름 끊김 없음
- **2s**: 사용자 인내 한계 (Nielsen Norman Group 표준)
- **10s+**: 사용자 이탈

#### Chaos 시뮬레이션과 정합
payment-service의 `CHAOS_MAX_DELAY=2000` 환경변수와 **정확히** 매핑. 의도:
- Chaos OFF: P99 ~500ms (정상)
- Chaos ON: P99 ~2s 근처 도달 → P99 알림 자연 트리거 → 알림 라우팅 검증

### 3.3 5xx 5% 선택 이유

#### 운영 표준
업계에서 "5%"는 명백한 사고 시점의 표준 임계치. 99.9% SLO 대비 50배 → 즉시 critical 분류.

#### Chaos 422와 임계치 분리
payment-service의 Chaos는 422로 매핑되므로 5xx 5% 임계치를 넘을 수 없음. 즉:
- Chaos만으로는 5xx 알림 발화 안 됨
- 5xx 알림 발화 = **진짜 인프라 사고**

이 분리는 의도적 설계 (ADR-0026). 알림이 false positive 없이 "진짜 사고"만 잡도록.

---

## 4. SLO 위반 대응 프로세스

### 4.1 5단계 표준 흐름

```
[탐지]      Prometheus 알림 발화
   ↓
[알림]      Alertmanager → Slack #ops-alert
   ↓
[분석]      Pod 상태 / 로그 / Grafana 대시보드 확인
   ↓
[조치]      해당 Runbook 실행 (docs/runbook/ 참조)
   ↓
[회고]      ADR 박제 + 함정 갱신 + Runbook 보강
```

각 단계의 상세 가이드는 [Runbook 폴더](./runbook/) 참조.

### 4.2 우선순위

| Severity | 조치 시간 | 담당 |
|---|---|---|
| **critical** (5xx > 5%, CrashLoopBackOff) | 즉시 (5분 이내) | 운영자 (1인 환경) |
| **warning** (P99 > 2s, NotReady 5m+) | 30분 이내 | 운영자 |

운영 환경 진입 시(Phase 5+):
- critical: 업무 시간 외 PagerDuty 에스컬레이션
- warning: 다음 영업일 검토

---

## 5. 에러 예산 (Error Budget) 운용

### 5.1 월간 에러 예산 = 0.1%

| 사용량 | 의미 | 행동 |
|---|---|---|
| 0~50% 소진 | 정상 | 신규 기능 배포 OK |
| 50~80% 소진 | 주의 | 배포 신중, 회고 작성 |
| 80~100% 소진 | 위험 | **배포 중단**, SLO 복구 우선 |
| 100% 초과 | SLO 위반 | 서비스 안정화 외 작업 동결 |

### 5.2 측정 PromQL

```promql
# 30일 누적 5xx 요청 수
sum(increase(http_server_requests_seconds_count{
  application=~"product-service|order-service|payment-service",
  status=~"5.."
}[30d]))

# 30일 전체 요청 수
sum(increase(http_server_requests_seconds_count{
  application=~"product-service|order-service|payment-service"
}[30d]))

# 에러 예산 사용률 (%)
(5xx_count / total_count) / 0.001 * 100
```

운영 환경에선 위 쿼리를 Grafana 패널로 시각화 + Slack 주간 리포트 발송 권장.

---

## 6. 본 SLO의 한계 (포트폴리오 환경 한정)

### 6.1 측정 데이터 부족
매일 destroy/apply 사이클 → 30일 rolling 측정 불가능. SLO 형식만 박제.

### 6.2 단일 가용성 정의
- "가용성 = 5xx 미발생"으로만 정의
- 운영 환경에선 다음 추가 필요:
  - DB 연결 가용성 (RDS healthcheck)
  - 분산 호출 가용성 (order → product / order → payment 각각)
  - 외부 API 가용성 (현재는 외부 API 없음)

### 6.3 사용자별 SLO 미적용
운영 환경에선 다음을 차등 적용:
- premium 고객: 99.95%
- 일반 고객: 99.9%
- 무료 사용자: best-effort

---

## 7. 변경 이력

| 일자 | 변경 | 사유 |
|---|---|---|
| 2026-05-03 | 본 문서 최초 작성 | 운영 표준화 |

---

## 8. 한마디로 정리

> "이 프로젝트의 SLO는 월간 가용성 99.9%, P99 응답 시간 2초, 5xx 에러율 5%로 정의했습니다. 특히 5xx 5% 임계치는 SLO 99.9%(=5xx 0.1%)의 50배라 명백한 사고 시점이고, payment-service의 Chaos 시뮬레이션은 422 매핑이라 5xx 임계치에 영향 없도록 설계해 알림이 false positive 없이 진짜 인프라 사고만 잡도록 했습니다.
>
> 측정은 Prometheus의 `http_server_requests_seconds_count` 메트릭으로 5분/30일 rolling window 기반이고, 위반 시 Alertmanager → Slack #ops-alert로 5단계 대응 프로세스(탐지→알림→분석→조치→회고)를 따릅니다. 각 사고 패턴은 Runbook으로 박제해 다음 사이클에 즉시 적용 가능하도록 했습니다."