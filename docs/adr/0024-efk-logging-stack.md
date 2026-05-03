# ADR-0024: EFK Logging Stack 도입 (Elasticsearch + Fluent Bit + Kibana)

- **Status**: Accepted
- **Date**: 2026-05-02
- **Deciders**: 1인 프로젝트 (DevOps 포트폴리오)
- **Phase**: Phase 4 Epic 8

## Context

portfolio-app은 product/order/payment 3개 마이크로서비스로 구성되며 분산 호출(order → product → payment)을 수행한다. K8s 배포 환경에서 다음 운영 요구사항이 발생했다.

1. **분산 호출 로그 추적**: RequestId(MDC)로 같은 요청의 흐름을 묶어서 봐야 함
2. **노드별 분산된 Pod 로그 중앙 집중**: `kubectl logs`로는 Pod 1개씩만 봐야 해 비효율
3. **rollout/scale 시 로그 휘발 방지**: Pod 재생성 시 stdout 로그도 사라짐
4. **운영 시연 자료**: 면접 어필용 Observability 풀스택 캡처

기존 결정:
- portfolio-app은 logback prod 프로파일에서 LogstashEncoder로 JSON 출력 (ADR-0003)
- RequestIdFilter로 MDC에 X-Request-Id 박제 (ADR-0005)

이 두 결정은 EFK 도입을 자연스럽게 만든다 — 이미 JSON 로그 + RequestId 박혀있으므로 수집·검색만 추가하면 분산 추적 가능.

## Decision

### Elasticsearch — raw manifest single Pod

다음 옵션을 비교 후 raw manifest single Pod 채택:

| 옵션 | 평가 |
|---|---|
| **bitnami/elasticsearch chart** | ❌ Elastic License (BSL) — public 레포에 commit 시 라이선스 표시 의무. single-node 모드에서 Pod 재생성 시 cluster state 잃는 사고 보고 다수 |
| **elastic/eck-stack (Operator)** | ❌ ECK Operator + CRD 의존. 1인 시연 환경에 과도. Operator 자체 디버깅 비용 |
| **raw manifest single Pod** ✅ | Helm 의존 0, 동작 명확. xpack.security 비활성화로 인증 복잡도 0. emptyDir storage로 휘발 의도 명확 |

설정:
```yaml
# logging/elasticsearch.yaml
- discovery.type: single-node
- xpack.security.enabled: false
- volumeMounts: emptyDir
```

### Fluent Bit — Helm chart 0.57.3, DaemonSet

Fluentd 대비 메모리 사용량 ~10x 절감 (4MB vs 40MB per Pod). 노드마다 DaemonSet 1개로 모든 Pod stdout 수집.

설정 핵심 (logging/fluent-bit/values.yaml):
```ini
[INPUT]
    Name     tail
    Path     /var/log/containers/*.log
    Tag      kube.*
    multiline.parser docker, cri

[FILTER]
    Name        kubernetes
    Merge_Log   On
    Merge_Log_Key log_processed   # JSON 로그를 log_processed.* 하위로 통합

[OUTPUT]
    Name             es
    Host             elasticsearch.logging.svc.cluster.local
    Port             9200
    Logstash_Format  On
    Logstash_Prefix  portfolio
    Time_Key         @timestamp
    Suppress_Type_Name On    # ES 8.x deprecated type 회피
```

결과 인덱스 패턴: `portfolio-YYYY.MM.DD` (시계열).

### Kibana — raw manifest + 별도 ALB Ingress

- xpack.security.enabled=false (인증 없음)
- ALB Ingress 별도 group(`group.name=kibana`) — 다른 ALB와 path 충돌 방지
- 시연용 path는 `/`

### 적용 방식 — ArgoCD App + raw kubectl 혼용 (ADR-0027 정합)

- **ArgoCD Application**: Fluent Bit (Helm chart 의존, sync 자동 재시도 가치)
- **kubectl apply 직접**: namespace, Elasticsearch, Kibana, kibana-ingress (raw K8s 자원, 단순 yaml)

## Consequences

### Positive

- **메모리 절감**: Fluentd 대비 ~10x (면접 어필용 정량 수치)
- **빠른 도입**: 사이클당 sync 시간 단축 (Helm 의존 적음)
- **분산 추적 가능**: RequestId로 같은 요청 묶어서 검색
  ```
  Discover 검색: log_processed.requestId : "abc-123"
  ```
- **설정 명확**: raw manifest로 모든 옵션 가시화

### Negative / Trade-off

- **HA 없음**: Elasticsearch single-node, Pod 재생성 시 데이터 휘발 (시연 환경 의도)
- **보안 비활성화**: xpack.security 끄면서 인증 없음. 외부 노출 시 즉시 사고 (시연 환경만)
- **운영 미적합**: HA / 보안 / 인덱스 라이프사이클 / 디스크 보존 정책 없음

### Future Work (Phase 5+)

- **bitnami chart 또는 ECK Operator 재검토**: 운영 환경(staging/prod) 진입 시 HA + Replica + Sharding 필요
- **Index Lifecycle Management(ILM)**: 7일 hot → 30일 warm → 90일 삭제 자동화
- **결제 서비스 로그 분리 인덱스**: `payments-logs-*` 별도 인덱스로 보안 감사 가능 구조

## References

- 함정 #28: in-memory DB Pod 분리 (분산 추적의 본질적 필요성 박제)
- ADR-0003: 구조화 로깅 (LogstashEncoder)
- ADR-0005: 분산 추적 — RequestId 인터셉터
- ADR-0027: K8s Manifest 적용 영역 분리
- 함정 #56: infrastructure/ingress 패턴 (kibana-ingress도 같은 패턴)

## Verification

- [x] Fluent Bit DaemonSet 2/2 Running
- [x] Elasticsearch 인덱스 생성 확인: `portfolio-2026.05.02` (57,433 docs / 25.8MB) — 부하 60초로 적재 검증
- [x] Kibana ALB 발급 + 200 응답
- [ ] Kibana data view 생성 + RequestId 검색 캡처 (다음 사이클)