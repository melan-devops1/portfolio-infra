# ADR-0025: 분산 추적 — Jaeger + OpenTelemetry Java Agent

- **Status**: Accepted
- **Date**: 2026-05-02
- **Deciders**: 1인 프로젝트 (DevOps 포트폴리오)
- **Phase**: Phase 4 Epic 9

## Context

portfolio-app은 분산 호출(order → product → payment)을 수행한다. 로그(EFK, ADR-0024) + RequestId 추적(ADR-0005)으로 텍스트 검색은 가능하지만 다음이 부족하다.

1. **Span timeline 시각화 부재**: 어느 호출이 얼마나 걸렸는지 시각적으로 못 봄
2. **호출 깊이 표현 불가**: order → product 간 latency vs payment 처리 latency 분리 어려움
3. **에러 발생 지점 시각화**: 어느 span에서 exception 발생했는지 timeline에서 즉시 식별 불가
4. **운영 시연 자료**: 면접에서 "분산 추적 timeline" 캡처는 가장 강력한 단일 자료

추가 제약:
- 앱 코드 변경 최소화 (DevOps 포지션, 앱 코드는 최소 품질만)
- 운영 환경에서는 trace 비활성화 가능해야 함 (성능 영향 + 인프라 비용)
- ADR-0024 EFK와 중복 회피 (logs는 Fluent Bit, metrics는 Prometheus)

## Decision

### Jaeger Helm chart 4.7.0 (app version 2.17.0), all-in-one 모드

| 옵션 | 평가 |
|---|---|
| **all-in-one** ✅ | 단일 Pod에 collector + query + agent 통합. 시연 환경에 적합. memory storage로 빠른 시작 |
| **production 모드** | collector/query/agent 분리. Cassandra/Elasticsearch backend. 운영 환경용. 1인 시연에 과도 |

설정 (tracing/values.yaml):
```yaml
allInOne:
  enabled: true
  args:
    - --memory.max-traces=10000   # 시연용 cap
storage:
  type: memory
collector:
  service:
    otlp:
      grpc: { name: otlp-grpc, port: 4317 }
      http: { name: otlp-http, port: 4318 }
```

**중요한 함정 (#54)**: all-in-one 모드는 단일 Service `jaeger`에 모든 포트 통합. 가정한 `jaeger-collector` / `jaeger-query` 분리 패턴은 production 모드에만 해당.

### OpenTelemetry Java Agent v2.26.1 — Dockerfile attach 패턴

Spring Boot 코드 변경 0. Dockerfile에 3줄 추가:

```dockerfile
ARG OTEL_AGENT_VERSION=2.26.1
ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar /opt/otel/opentelemetry-javaagent.jar
RUN chmod 644 /opt/otel/opentelemetry-javaagent.jar
```

ENTRYPOINT 변경 없음 — agent는 K8s deployment.yaml의 환경변수로만 활성화.

### K8s deployment.yaml의 환경변수로 활성화/비활성

```yaml
- name: JAVA_TOOL_OPTIONS
  value: "-javaagent:/opt/otel/opentelemetry-javaagent.jar"
- name: OTEL_SERVICE_NAME
  value: "<service-name>"   # product / order / payment
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://jaeger.tracing.svc.cluster.local:4317"
- name: OTEL_EXPORTER_OTLP_PROTOCOL
  value: "grpc"
- name: OTEL_RESOURCE_ATTRIBUTES
  value: "deployment.environment=dev,service.namespace=portfolio"
- name: OTEL_TRACES_SAMPLER
  value: "always_on"        # 시연용 100% 샘플링 — 운영에선 1~10%
- name: OTEL_METRICS_EXPORTER
  value: "none"             # Prometheus와 중복 회피
- name: OTEL_LOGS_EXPORTER
  value: "none"             # Fluent Bit와 중복 회피
```

`JAVA_TOOL_OPTIONS` 환경변수 안 박으면 agent 자동 비활성. 운영 환경에서 trace 끄려면 이 env 제거만으로 충분.

### Exporter 분리 — traces only

3축 Observability 중복 회피:
- **Metrics**: Prometheus (already)
- **Logs**: Fluent Bit + Elasticsearch (ADR-0024)
- **Traces**: Jaeger (this ADR)

OpenTelemetry agent는 모두 export 가능하지만 metrics/logs는 명시적으로 `none` 설정. 미래에 OpenTelemetry Collector로 통합 시 검토.

## Consequences

### Positive

- **앱 코드 변경 0**: agent attach 패턴, 운영 friction 최소
- **활성화/비활성 명확**: `JAVA_TOOL_OPTIONS` env 1개로 제어
- **시연 timeline 강력**: order span → product span → payment span을 timeline으로 시각화
- **Service Mesh 호환**: 향후 Istio sidecar 도입 시 trace context propagation 자연스럽게 통합

### Negative / Trade-off

- **trace 휘발**: memory storage라 Pod 재생성 시 모든 trace 사라짐 (시연 환경 의도)
- **샘플링 100%**: 시연용 always_on, 운영 환경에선 비용 폭발 — Phase 5+ probability sampler로 변경 필요
- **agent 메모리 오버헤드**: ~50~100MB per Pod 추가. 시연 노드(t3.large)에선 무시 가능
- **3rd-party agent 보안**: agent jar이 ADD로 빌드 시 다운로드. 공급망 공격 가능성 (Phase 5+ Trivy + cosign 검토)

### Future Work (Phase 5+)

- **Service Mesh(Istio) 도입 시**: sidecar가 trace context 자동 propagation. agent 제거 가능
- **샘플링 비율 조정**: `OTEL_TRACES_SAMPLER=parentbased_traceidratio` + `OTEL_TRACES_SAMPLER_ARG=0.01` (1%)
- **OpenTelemetry Collector 도입**: agent → Collector → multi-backend (Jaeger + Prometheus + Loki)
- **production 모드**: Cassandra 또는 Elasticsearch backend로 trace 영구 보존

## References

- ADR-0005: 분산 추적 — RequestId 인터셉터 (이번 ADR의 진화)
- ADR-0024: EFK Stack 도입 (logs)
- ADR-0027: K8s Manifest 적용 영역 분리
- 함정 #54: Jaeger Service 이름 (deployment.yaml + ingress.yaml 두 곳)
- OpenTelemetry Java Agent: https://github.com/open-telemetry/opentelemetry-java-instrumentation

## Verification

- [x] OTel agent attach: `[otel.javaagent ...] opentelemetry-javaagent - version: 2.26.1` 로그
- [x] OTEL_EXPORTER_OTLP_ENDPOINT 환경변수 — `http://jaeger.tracing.svc.cluster.local:4317`
- [x] Jaeger Pod Running, Service `jaeger` 14개 포트 노출
- [x] Jaeger ALB 200 응답 (jaeger-ingress backend 수정 후)
- [ ] Jaeger UI에서 분산 호출 timeline 캡처 (다음 사이클)