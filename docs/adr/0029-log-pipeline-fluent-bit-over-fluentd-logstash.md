# ADR-0029: 로그 파이프라인 — Fluent Bit Only (Fluentd 미채택, Logstash 미도입)

- **상태**: Accepted
- **일자**: 2026-05-03
- **결정자**: 1인 dev (포트폴리오)
- **관련 ADR**: ADR-0024 (EFK Logging Stack), ADR-0028 (로그 플랫폼)

---

## 1. 맥락

ADR-0024에서 Fluent Bit을 채택했으나 다음 두 결정의 근거는 별도 ADR이 필요:

1. **Fluentd vs Fluent Bit**: 왜 Fluentd 거치지 않고 Fluent Bit만 채택했는가?
2. **Logstash 도입 여부**: EFK가 ELK의 'L'(Logstash) 자리에 'F'(Fluent Bit)를 두는 패턴인데, Logstash 별도 도입이 필요한 시점은?

특히 본 프로젝트의 심화 요건 중 하나가 "서비스별 로그 필터링 규칙 (민감 데이터 마스킹, 에러 레벨 자동 분류)"인데, 이를 Fluent Bit 단독으로 충족 가능한지 검증 필요.

---

## 2. Fluentd vs Fluent Bit 비교

### 2.1 핵심 사양

| 항목 | Fluentd | Fluent Bit |
|---|---|---|
| **언어** | Ruby + C 확장 | C |
| **메모리 풋프린트** | ~40MB (idle) | ~1MB (idle), ~10-30MB (under load) |
| **CPU 부하** | Ruby GC 영향 | 낮음 |
| **플러그인 수** | 1000+ (가장 많음) | 100+ (꾸준히 증가) |
| **버퍼링** | 디스크/메모리 (성숙) | 디스크/메모리 (성숙) |
| **K8s metadata enrich** | fluent-plugin-kubernetes_metadata | kubernetes filter (built-in) |
| **DaemonSet 적합성** | 무거움 | 경량 (Pod당 ~10MB 노드 부담) |

### 2.2 메모리 절감 — 일반적으로 알려진 ~10x 차이

업계 표준 비교 결과:
- Fluentd: ~40MB / Pod (idle), ~100MB+ under load
- Fluent Bit: ~1-10MB / Pod (idle), ~30MB under load

EKS 노드 4대 환경에서:
- Fluentd: 노드당 ~100MB × 4 = 400MB 메모리 점유
- Fluent Bit: 노드당 ~30MB × 4 = 120MB 메모리 점유

(주의: 본 프로젝트에선 직접 측정하지 않았음. Fluentd 거치지 않고 Fluent Bit 단독 채택. 측정 데이터는 업계 보고 인용.)

### 2.3 본 프로젝트의 채택 이유

1. **DaemonSet 패턴 정합** — 모든 노드에 sidecar처럼 배치되므로 경량성이 1순위
2. **K8s 우선 설계** — kubernetes filter built-in, ServiceAccount + RBAC 표준 박제
3. **출력 안정성** — Elasticsearch output 플러그인 production 검증
4. **Helm chart 성숙도** — fluent/fluent-bit Helm chart 안정 운영 (현재 0.57.3)

### 2.4 Fluentd가 더 적합한 경우 (본 ADR 미채택)

다음 조건 부합 시 Fluentd 또는 Fluent Bit + Fluentd aggregator 패턴 검토:
- 1000+ 종 source/destination 동시 처리
- 복잡한 조건부 분기 라우팅 (`<match>` 다단)
- Ruby 생태계 활용 (fluent-plugin-* 1000+개 중 특수 사용 사례)

본 프로젝트 단일 source(K8s 컨테이너 stdout) → 단일 destination(Elasticsearch) 구조이므로 Fluent Bit 단독으로 충분.

---

## 3. Logstash 도입 여부 검토

### 3.1 ELK 표준 아키텍처에서 Logstash의 역할

```
[원본 로그] → [Beats / Fluent Bit] → [Logstash] → [Elasticsearch] → [Kibana]
                                       ↑
                          파싱 / 필터링 / 변환 / 보강 (heavy lifting)
```

Logstash 핵심 역할:
- **grok 패턴**: 비구조화 텍스트 → 구조화 필드 추출
- **mutate**: 필드 변환 (rename, convert, gsub)
- **drop**: 조건부 로그 폐기
- **dissect**: 고정 형식 빠른 파싱
- **enrich**: 외부 lookup (DB, GeoIP)

### 3.2 본 프로젝트의 요건 ↔ Fluent Bit 충족 여부

심화 요건 항목별 검증:

| 요건 | Logstash 표준 방식 | Fluent Bit 대응 |
|---|---|---|
| 서비스별 로그 분류 | `if [kubernetes][labels][app]` 분기 | kubernetes filter + tag rewriting |
| 민감 데이터 마스킹 | `mutate { gsub => [...] }` | modify filter / lua filter |
| 에러 레벨 자동 분류 | `if [level] == "ERROR"` | grep filter (level=ERROR 분리 출력) |
| 멀티라인 stack trace | `multiline codec` | multiline filter (Java/Python parser 내장) |
| JSON 파싱 | `json filter` | parser plugin (json) |
| 시간 정규화 | `date filter` | parser plugin time_format |

**모든 심화 요건은 Fluent Bit 단독으로 충족 가능**.

### 3.3 본 프로젝트 Fluent Bit 구성 예시 (values.yaml 기반)

```yaml
config:
  filters: |
    [FILTER]
        Name                kubernetes
        Match               kube.*
        Merge_Log           On
        K8S-Logging.Parser  On
        K8S-Logging.Exclude On
    
    # 민감 데이터 마스킹 (modify 필터)
    [FILTER]
        Name    modify
        Match   kube.*
        # password / token / authorization 헤더 마스킹
        Hard_rename password REDACTED_password
        Hard_rename token    REDACTED_token
    
    # JSON 메시지 파싱 후 level 추출
    [FILTER]
        Name        parser
        Match       kube.*
        Key_Name    log
        Parser      json
        Reserve_Data On
    
    # ERROR 로그만 별도 인덱스 (선택)
    [FILTER]
        Name    rewrite_tag
        Match   kube.*
        Rule    $level ERROR portfolio-error.* false

  outputs: |
    [OUTPUT]
        Name            es
        Match           kube.*
        Host            elasticsearch.logging.svc
        Port            9200
        Logstash_Format On
        Logstash_Prefix portfolio
        Retry_Limit     False
    
    [OUTPUT]
        Name            es
        Match           portfolio-error.*
        Host            elasticsearch.logging.svc
        Port            9200
        Logstash_Format On
        Logstash_Prefix portfolio-error
        Retry_Limit     False
```

### 3.4 Logstash가 필요해지는 조건

본 ADR을 supersede할 새 ADR이 필요한 시점:
- **복잡한 grok 패턴 필요** (예: legacy 시스템 비구조화 로그)
- **외부 enrich 필요** (예: GeoIP lookup, RDB lookup)
- **다중 destination 분기** (예: hot path는 ES, cold path는 S3)
- **rate limiting / dedup** 필요 (Logstash filter plugin 활용)

본 프로젝트는 **Spring Boot Logback structured JSON 로그**를 stdout으로 내보내고 있어 grok 불필요. 1순위 결정 유지.

---

## 4. 결정

다음 두 결정을 본 ADR에 통합 명시:

### 결정 A: Fluentd 미채택, Fluent Bit 단독 채택
**근거**: DaemonSet 경량성 + K8s 통합 + 단일 source/destination 구조

### 결정 B: Logstash 미도입
**근거**: 본 프로젝트의 심화 요건(필터링, 마스킹, 분류)은 Fluent Bit 표준 filter로 충족. 추가 인프라 컴포넌트(JVM 기반 Logstash) 운영 부담 정당화 안 됨.

---

## 5. 결과 / Trade-off

### 5.1 얻는 것
- 인프라 단순화: collection layer 1개 (Fluent Bit DaemonSet)만 운영
- 메모리 절감: 노드당 ~30MB (Fluentd 대비 ~70% 감소, 업계 보고 기준)
- 운영 부담 감소: JVM 튜닝(Logstash) 또는 Ruby GC 모니터링(Fluentd) 불필요
- ECS 표준 필드(application, kubernetes.*) 자동 박제

### 5.2 잃는 것
- Fluentd의 풍부한 플러그인 생태계 (1000+) 활용 기회
- Logstash의 grok 패턴 라이브러리 (legacy 로그 호환성)
- 복잡한 조건부 라우팅의 표현력

### 5.3 직접 측정 데이터 부재 (정직한 한계)

본 결정의 메모리 절감 근거는 **업계 보고 인용**이며 본 환경에서 직접 비교 측정은 진행하지 않음. 운영 환경 진입 시 다음 측정 권장:
- Fluentd vs Fluent Bit 동일 부하 환경에서 RSS/CPU 비교
- p99 로그 처리 지연 시간
- 로그 손실률 (under burst load)

---

## 6. 운영 환경 진화 경로

### 6.1 hybrid 패턴 (~Phase 5+ 가정)
```
[Pod logs] → [Fluent Bit DaemonSet (collection)]
                    ↓
             [Fluent Bit aggregator StatefulSet (buffering, routing)]
                    ↓
             [Elasticsearch / S3 / Kafka]
```

aggregator를 둠으로써:
- DaemonSet 부담 추가 감소
- 중앙 집중 라우팅 정책 박제
- destination 장애 시 buffering layer 분리

### 6.2 Logstash 도입 정당화 시나리오
- 인프라가 ELK Cloud 매니지드로 이전 (Logstash가 packaged)
- legacy 시스템(웹 서버 access log 등) 비구조화 로그 통합
- enrichment(GeoIP, threat intel) 요건 추가

이 경우 본 ADR은 supersede되며 새 ADR 작성.

---

## 7. 참고 자료

- ADR-0024: EFK Logging Stack 도입 (본 ADR이 세부 결정 심화)
- ADR-0028: 로그 플랫폼 — Elasticsearch over Splunk
- Fluent Bit 공식: https://docs.fluentbit.io/manual/pipeline
- 함정 #56 (PROJECT_CONTEXT.md): EFK ingress 미적용 패턴

---

## 8. 한마디로 정리

> "Fluent Bit 단독 채택과 Logstash 미도입 두 결정을 ADR-0029에 통합 명시했습니다.
>
> 첫째 Fluentd vs Fluent Bit. DaemonSet 패턴에서 노드당 메모리 풋프린트가 핵심 결정 요인입니다. Fluentd ~40MB vs Fluent Bit ~10MB (idle 기준, 업계 보고). 4노드 클러스터에서 노드당 30MB ~ 100MB 차이는 운영 환경에선 무시할 수 없는 자원 비용입니다. 본 프로젝트는 단일 source(K8s stdout) → 단일 destination(ES) 구조라 Fluent Bit의 100여 개 플러그인으로 충분히 충족됩니다.
>
> 둘째 Logstash. EFK가 ELK의 L 자리에 F를 두는 패턴인 이유는, 본 환경처럼 Spring Boot Logback이 structured JSON을 stdout으로 내보내면 grok 같은 비구조화 파싱이 불필요하기 때문입니다. 심화 요건인 민감 데이터 마스킹은 Fluent Bit modify 필터, 에러 레벨 자동 분류는 grep + rewrite_tag 필터로 표준 충족. JVM 기반 Logstash 도입의 운영 부담을 정당화할 근거가 없습니다.
>
> 다만 직접 측정 데이터가 아닌 업계 보고 인용이라는 점, Logstash가 필요해지는 조건(grok 패턴, enrichment, 다중 destination 분기)도 ADR에 명시해 운영 환경 진입 시 본 ADR을 supersede할 새 ADR 작성하도록 기록했습니다."