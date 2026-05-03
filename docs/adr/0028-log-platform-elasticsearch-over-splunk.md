# ADR-0028: 로그 플랫폼 — Elasticsearch over Splunk

- **상태**: Accepted
- **일자**: 2026-05-03
- **결정자**: 1인 dev (포트폴리오)
- **관련 ADR**: ADR-0024 (EFK Logging Stack), ADR-0029 (Log Pipeline)
- **Supersedes**: ADR-0024의 일부 (플랫폼 선택 근거를 본 ADR로 분리·심화)

---

## 1. 맥락

Phase 4 Epic 8 EFK 도입 시 "왜 Elasticsearch인가"의 근거를 ADR-0024에 간단히 명시했으나, 다음 질문에 답하는 별도 ADR이 필요:

- 운영 비용은 어떻게 비교되는가?
- 검색 성능 차이는 어떤가?
- 확장성 한계는 어디서 갈리는가?
- 본 프로젝트의 스케일에 어느 쪽이 적합한가?

업계 사실상 표준 두 옵션:
- **Splunk** (Splunk Enterprise / Splunk Cloud Platform) — 상용, ingest 기반 라이선스
- **Elasticsearch** (ELK / EFK 스택) — Elastic 라이선스(ELv2/AGPL) + 자체 호스팅 또는 Elastic Cloud

---

## 2. 비교 분석

### 2.1 운영 비용

| 항목 | Splunk | Elasticsearch |
|---|---|---|
| **라이선스 모델** | ingest 기반 (GB/day) | 자체 호스팅 무료, 매니지드는 리소스 기반 |
| **50GB/day 연간 비용** | ~$15,000 (라이선스만) | ~$8,000 (Elastic Cloud 상용 패키지) / ~$0 (자체 호스팅 + AWS 인프라 비용) |
| **500GB/day 연간 비용** | $150,000+ | 자체 호스팅 시 인프라 비용만 (~$30K-50K) |
| **숨겨진 비용** | overage 요금, premium 지원 15-25%, 전문 서비스, 앱 마켓 | 운영 인력 (JVM 튜닝, shard 관리, ILM 구성) |
| **Cisco 인수 영향 (2024)** | 가격 인상 + 로드맵 불확실성 보고됨 | 영향 없음 |

핵심 trade-off:
- **Splunk**: 라이선스 비용 ↑ → 운영 인력 비용 ↓ (관리 단순)
- **Elasticsearch**: 라이선스 비용 ↓ → 운영 인력 비용 ↑ (JVM/shard/ILM 직접 운영)

본 프로젝트(1인 dev)는 운영 인력 비용이 0이므로 Elasticsearch가 압도적으로 유리. 운영 환경에선 손익분기점 ~200GB/day로 알려져 있음.

### 2.2 검색 성능

| 항목 | Splunk | Elasticsearch |
|---|---|---|
| **인덱싱 모델** | schema-on-read (검색 시 필드 추출) | schema-on-write (인입 시 필드 추출) |
| **쿼리 언어** | SPL (proprietary, pipe-based) | KQL / Query DSL (JSON, Lucene 기반) |
| **첫 검색 응답** | 매우 빠름 (인덱싱 단계의 비용) | 인덱스 구성에 따라 |
| **복잡한 집계** | SPL의 `stats`, `eventstats` 등 직관적 | aggregation API, 학습 곡선 큼 |
| **저장 효율** | 원본 + 인덱스 중복 저장 (스토리지 ↑) | 압축 효율 좋음 |

성능 자체는 두 플랫폼 모두 production 검증됨. 차이는 **쿼리 언어 학습 곡선**:
- SPL: SOC/SRE 표준, 익숙해지면 생산성 높음, 그러나 **proprietary lock-in**
- KQL/Query DSL: Lucene 기반 표준, 다른 도구(OpenSearch 등)로 마이그레이션 가능

### 2.3 확장성

| 항목 | Splunk | Elasticsearch |
|---|---|---|
| **수평 확장** | indexer 추가 (per-indexer 비용) | data node 추가 |
| **데이터 티어링** | hot/warm/cold/frozen 단계 (S3SmartStore) | hot/warm/cold/frozen + searchable snapshot |
| **단일 클러스터 한계** | 일반적으로 수십 PB | 일반적으로 수 PB (shard 수 한계) |
| **튜닝 부담** | 적음 (관리형은 0) | JVM heap, shard 크기, refresh interval, ILM 등 |

### 2.4 통합 및 생태계

| 항목 | Splunk | Elasticsearch |
|---|---|---|
| **K8s 통합** | Splunk Connect for K8s (별도 운영) | Fluent Bit/Fluentd → ES 직접 (성숙) |
| **APM/Tracing** | Splunk Observability Cloud (별도 SKU) | Elastic APM (같은 스택) |
| **메트릭** | Splunk IT Service Intelligence (별도 SKU) | Metricbeat → ES (같은 스택) |
| **SIEM** | Splunk Enterprise Security (강력) | Elastic Security (성숙) |

본 프로젝트는 메트릭(Prometheus)/추적(Jaeger)이 별도 스택이라 통합 이점 활용 안 함. 하지만 **Phase 5+ Single Pane of Glass 진화 경로**에선 Elastic의 통합 우위가 의미 있음.

---

## 3. 결정

**Elasticsearch (EFK 스택)를 채택**한다. 본 ADR은 ADR-0024의 플랫폼 선택 근거를 심화·확정한다.

### 3.1 결정 이유 (우선순위 순)

1. **포트폴리오 비용 제약 (1순위)**
   - Splunk Cloud 50GB/day ~$15K/year는 1인 dev 포트폴리오 예산 초과
   - Elasticsearch 자체 호스팅 + AWS EC2(t3.medium 1대) = 매 사이클 destroy/apply로 시간당 비용만 발생
   - 학습 비용 0, 인프라 비용 ~$10/cycle

2. **취업 시장 가시성 (2순위)**
   - EFK/ELK는 K8s 운영 직무 채용 공고에서 표준 명시
   - SPL은 보안 분야 외엔 체감 빈도 낮음
   - 면접관이 "Logstash/Fluentd 차이"는 흔히 묻지만 "SPL pipe 명령" 묻는 경우는 드묾

3. **타 스택과의 정합 (3순위)**
   - 본 프로젝트는 metrics(Prometheus/Grafana) + traces(Jaeger) + logs(EFK)로 분산
   - K8s + Prometheus + Jaeger 조합은 EFK와 자연스럽게 어울림
   - Splunk 단일 플랫폼 통합 이점은 metrics/traces도 Splunk로 가야 살아남는 패턴

4. **마이그레이션 자유도 (4순위)**
   - Elasticsearch → OpenSearch 포크 가능
   - SPL → 다른 플랫폼 migrating은 사실상 재작성
   - lock-in 회피

### 3.2 본 프로젝트의 EFK 구성 (ADR-0024 정합)

- **Elasticsearch**: raw manifest single Pod, version 8.15.0
- **Fluent Bit**: Helm chart 0.57.3, log forwarding only (ADR-0029)
- **Kibana**: raw manifest, version 8.15.0
- **인덱스**: `portfolio-*` (Logstash_Prefix 정합)
- **수명**: 매 사이클 destroy/apply 리셋, ILM 미적용 (포트폴리오 한계)

---

## 4. 결과 / Trade-off

### 4.1 얻는 것
- 라이선스 비용 0
- K8s 운영 직무 면접 공통 화제 확보
- 마이그레이션 자유도 (OpenSearch 등)
- metrics/traces와 분리된 명확한 역할 분담

### 4.2 잃는 것
- 운영 인력 비용 부담 (1인 dev라 0이지만 운영 환경 진입 시 부각)
- single pane of glass 통합 미실현
- SPL 학습 기회 (보안 분야 진입 시 별도 보충 필요)

### 4.3 운영 환경 진화 경로 (Phase 5+ 가정)

| 단계 | 권장 옵션 |
|---|---|
| ~50GB/day | 본 결정 유지 (자체 호스팅 EFK 또는 OpenSearch on AWS) |
| 50~200GB/day | Elastic Cloud 매니지드 검토 (운영 부담 ↓) |
| 200GB/day~ | Splunk vs Elastic 재평가 — 운영 인력 vs 라이선스 trade-off 손익분기점 |
| 보안 SIEM 핵심 | Splunk Enterprise Security 또는 Elastic Security |

진입 단계에 Splunk POC가 정당화되는 경우만 본 ADR을 supersede할 새 ADR 작성.

---

## 5. 참고 자료

- ADR-0024: EFK Logging Stack 도입 (본 ADR이 supersede 일부)
- ADR-0029: Log Pipeline (Fluent Bit only, Logstash 미도입)
- 함정 #56 (PROJECT_CONTEXT.md): EFK ingress 미적용 패턴
- 검증 데이터: 2026 시점 Splunk Cloud ~$100-180/GB/day, Elastic Cloud ~$95/month 시작 (외부 가격 자료 참고)

---

## 6. 한마디로 정리

> "본 프로젝트는 EFK를 채택했고, Splunk 대비 결정 근거는 ADR-0028에 비교 분석으로 정리했습니다. 핵심은 세 축의 trade-off입니다.
>
> 첫째 비용. Splunk Cloud는 50GB/day 기준 연 $15K에서 시작해 ingest 비례 증가, 반면 Elasticsearch는 자체 호스팅 시 라이선스 0 + 인프라 비용만. 1인 포트폴리오엔 Elastic 압도적 유리지만, 운영 인력 비용을 포함한 TCO는 약 200GB/day 부근에서 손익분기점이 형성된다고 알려져 있습니다.
>
> 둘째 성능. 두 플랫폼 모두 production 검증됐고 차이는 쿼리 언어 학습 곡선과 lock-in. SPL은 SOC 표준이지만 proprietary, KQL/Query DSL은 Lucene 기반으로 OpenSearch 등 다른 플랫폼으로 마이그레이션 가능합니다.
>
> 셋째 생태계. K8s + Prometheus + Jaeger 조합은 EFK와 자연스러운 정합성, Splunk의 single pane of glass 이점은 metrics/traces도 Splunk로 통일해야 살아납니다.
>
> 운영 환경 진화 경로도 명시했고, 200GB/day 이상이거나 SIEM 요건이 강하면 본 ADR을 supersede할 새 ADR 작성 예정으로 함께 기록했습니다."