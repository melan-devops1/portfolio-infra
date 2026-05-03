# ADR-0026: AlertmanagerConfig matcherStrategy 결정 (None)

- **Status**: Accepted
- **Date**: 2026-05-02
- **Deciders**: 1인 프로젝트 (DevOps 포트폴리오)
- **Phase**: Phase 4 Epic 7-B
- **Supersedes**: 없음
- **Refs**: 함정 #57

## Context

ADR-0022(Observability Metrics)로 kube-prometheus-stack이 monitoring namespace에 설치됨. PrometheusRule + AlertmanagerConfig를 추가해 portfolio-app의 5xx 에러율 / P99 지연 알림을 Slack으로 발송하려 했다.

배치:
- **AlertmanagerConfig**: monitoring namespace에 위치 (`portfolio-alertmanager-config`)
- **portfolio-app**: default namespace에서 동작
- **알림 규칙**: monitoring namespace의 PrometheusRule이 default namespace 앱 metric 평가

부하 시연 시 모든 알림이 Alertmanager의 default `null` receiver로 빠지는 사고 발생. Slack 알림 미도착.

## Diagnosis

진단 5단계로 원인 좁힘:

### 1. Prometheus alerts 상태 — 정상 firing
```bash
kubectl exec -n monitoring -it prometheus-...-0 -c prometheus -- \
  wget -qO- http://localhost:9090/api/v1/alerts
```
KubeCPUOvercommit 등 알림은 정상 firing.

### 2. Alertmanager 받은 알림 — receiver=null로 라우팅
```json
"receivers": [{"name": "null"}]
```
받기는 했는데 우리 Slack receiver로 안 감.

### 3. AlertmanagerConfig label/selector — 정상
```yaml
labels:
  release: kube-prometheus-stack   # ✅
alertmanagerConfigSelector: {}     # 빈 selector — 모든 config 통합
```

### 4. webhook URL — 정상
직접 호출 시 `ok` 응답. Slack에 메시지 도착.

### 5. Alertmanager runtime config — **함정 발견**
```yaml
route:
  receiver: "null"
  routes:
  - receiver: monitoring/portfolio-alertmanager-config/slack-default
    matchers:
    - namespace="monitoring"        ### ← prometheus-operator가 자동 prefix
    routes:
    - matchers: [severity="critical"]
      receiver: ...slack-critical
    - matchers: [severity="warning"]
      receiver: ...slack-warning
```

**원인 확정**: prometheus-operator의 default `matcherStrategy=OnNamespace`가 모든 sub-route에 `namespace="<config-ns>"` matcher를 자동 prefix. AlertmanagerConfig가 monitoring namespace에 있으므로 `namespace="monitoring"` matcher 박힘. KubeCPUOvercommit 등 알림은 `namespace` label이 다르거나 없어 우리 sub-route 안 잡힘 → default `null` 빠짐.

이 동작은 멀티 테넌트 격리 의도 — 한 namespace의 AlertmanagerConfig가 다른 namespace 알림을 가로채지 못하도록.

## Decision

`monitoring/kube-prometheus-stack/values.yaml`에 명시:

```yaml
alertmanager:
  alertmanagerSpec:
    alertmanagerConfigMatcherStrategy:
      type: None
```

### 옵션 비교

| 옵션 | 평가 |
|---|---|
| **type: None** ✅ | namespace prefix 비활성화. AlertmanagerConfig 매처가 정의한 그대로 적용. 1인 프로젝트라 멀티 테넌트 격리 무관 |
| **type: OnNamespace** (default) | 멀티 테넌트 격리 강제. 본 사례에서는 함정 발생 |
| **PrometheusRule에 `namespace=monitoring` label 강제** | 시멘틱 부정확 (default 앱 알림인데 namespace label이 monitoring). 임시 회피용으로만 적합 |

## Consequences

### Positive

- AlertmanagerConfig sub-route가 정의한 매처 그대로 적용 (severity=warning/critical)
- monitoring namespace 위치 config가 모든 namespace 알림 라우팅 가능
- 1인 프로젝트의 단일 Slack 채널로 모든 알림 통합 라우팅 자연스러움

### Negative / Trade-off

- **멀티 테넌트 격리 비활성화**: 다른 namespace의 AlertmanagerConfig가 우리 매처를 가로챌 가능성. 1인 프로젝트라 무관
- 운영 환경(여러 팀의 namespace 공존)에서는 `OnNamespace` 유지 + namespace 명시 매처 사용 패턴 권장

### Future Work

- **운영 환경 진입 시 재검토**: 팀별 namespace 분리되면 `OnNamespace`로 복귀 + 각 팀 namespace에 자체 AlertmanagerConfig 배치 패턴
- **App-of-Apps 도입(Phase 5+)**: monitoring stack을 별도 Application으로 관리하면 values.yaml 자동 반영

## Verification

### 변경 전 (사고 상태)
```yaml
- receiver: ...slack-default
  matchers:
  - namespace="monitoring"   ### ← 자동 추가
  routes:
    - severity=critical
    - severity=warning
```

### 변경 후 (해결)
```yaml
- receiver: ...slack-default
  group_by: [alertname, application]
  routes:                     ### namespace prefix 사라짐
    - matchers: [severity="critical"]
    - matchers: [severity="warning"]
```

### 시연 검증
- 강제 알림 주입(severity=warning) → `slack-warning` receiver로 라우팅 확인
- Slack `#ops-alert` 채널에 알림 도착 캡처 확보

## References

- 함정 #57: 본 사고의 박제 (PROJECT_CONTEXT.md)
- ADR-0022: Observability Metrics (kube-prometheus-stack 채택)
- prometheus-operator 공식 문서: alertmanagerConfigMatcherStrategy