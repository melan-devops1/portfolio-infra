# Runbook: Alertmanager → Slack 알림 미도착

> **알림 규칙은 firing 중인데 Slack `#ops-alert` 채널에 메시지 안 옴**일 때 진단/조치 표준 절차.

- **버전**: 1.0
- **최초 작성**: 2026-05-03
- **사고 사례**: Phase 4 Epic 7-B 알림 시연 (2026-05-02)
- **관련 함정**: #57 (matcherStrategy=OnNamespace의 namespace 자동 prefix)
- **관련 ADR**: ADR-0026 (matcherStrategy=None)

---

## 1. 증상

### 1.1 신호
- Prometheus UI의 Alerts 탭에서 알림 firing 상태 확인됨
- Alertmanager UI에서도 알림 received 확인됨
- 그러나 Slack `#ops-alert` 채널에 알림 메시지 도착 안 함

### 1.2 빠른 점검 — 같은 사고인지 확인

```bash
# 1) 부하 또는 강제 알림 트리거
kubectl exec -n monitoring -it alertmanager-kube-prometheus-stack-alertmanager-0 \
  -c alertmanager -- amtool alert add TestAlert \
  severity=warning team=portfolio \
  --alertmanager.url=http://localhost:9093

# 2) 30초 대기 후 Slack 확인
# 3) Slack에 알림 안 오면 본 Runbook 진행
```

---

## 2. 진단 5단계 (Phase 4 Epic 7-B 실제 사고 흐름)

### Step 1 — Prometheus alerts 발화 상태 확인

```bash
kubectl exec -n monitoring -it prometheus-kube-prometheus-stack-prometheus-0 \
  -c prometheus -- wget -qO- http://localhost:9090/api/v1/alerts | jq '.data.alerts'
```

**기대**: 알림 1개 이상 `state: firing` 상태.

판단:
- 알림 firing 0개 → PrometheusRule 자체 미발화. 임계치 검토 (다른 Runbook).
- 알림 firing 1개 이상 → **Step 2 진행** (본 Runbook 적용 가능)

### Step 2 — Alertmanager가 받은 알림의 receiver 확인

```bash
kubectl exec -n monitoring -it alertmanager-kube-prometheus-stack-alertmanager-0 \
  -c alertmanager -- wget -qO- http://localhost:9093/api/v2/alerts \
  | jq '.[] | {labels: .labels, receivers: .receivers}'
```

**찾을 패턴 — 사고 신호**:

```json
{
  "labels": {
    "alertname": "HighErrorRate",
    "severity": "critical"
  },
  "receivers": [{"name": "null"}]   ← ⚠️ 사고 신호
}
```

`receivers` 배열에 `"null"`만 있으면 → **본 Runbook 적용 확정**. AlertmanagerConfig의 sub-route가 안 잡히고 default `null` receiver로 빠지는 것.

### Step 3 — AlertmanagerConfig label 확인

```bash
kubectl get alertmanagerconfig portfolio-alertmanager-config -n monitoring \
  -o jsonpath='{.metadata.labels}'
```

**기대**: `{"release":"kube-prometheus-stack"}` 포함.

label 누락 시:
```bash
kubectl label alertmanagerconfig portfolio-alertmanager-config -n monitoring \
  release=kube-prometheus-stack
```

### Step 4 — Slack webhook URL 직접 검증

```bash
# Secret에서 webhook URL 추출
WEBHOOK_URL=$(kubectl get secret alertmanager-slack-webhook -n monitoring \
  -o jsonpath='{.data.url}' | base64 -d)
echo "$WEBHOOK_URL" | head -c 50

# 직접 호출 — Slack에 도착하는지
curl -X POST -H 'Content-type: application/json' \
  --data '{"text":"webhook test from runbook"}' \
  "$WEBHOOK_URL"
# 응답 "ok"
```

**판단**:
- Slack에 메시지 도착 → **Step 5 진행** (Alertmanager 라우팅 사고 확정)
- Slack에 메시지 안 옴 → webhook URL 만료/재발급 필요 (Slack App 설정으로)

### Step 5 — Alertmanager runtime config의 matcher 확인 ⭐ (핵심)

```bash
kubectl exec -n monitoring -it alertmanager-kube-prometheus-stack-alertmanager-0 \
  -c alertmanager -- wget -qO- http://localhost:9093/api/v2/status \
  | jq -r '.config.original' | grep -A 20 "route:"
```

**찾을 패턴 — 사고 신호**:

```yaml
route:
  receiver: "null"
  routes:
    - receiver: monitoring/portfolio-alertmanager-config/slack-default
      matchers:
        - namespace="monitoring"   ← ⚠️ 자동 추가된 prefix (사고 원인)
      routes:
        - matchers: [severity="critical"]
          receiver: ...slack-critical
        - matchers: [severity="warning"]
          receiver: ...slack-warning
```

**진단 확정**: `namespace="monitoring"` matcher가 sub-route에 자동 추가됨.

---

## 3. 진단 결과 — 사고 원인 (함정 #57)

### 3.1 prometheus-operator의 default 동작

`alertmanagerConfigMatcherStrategy.type` 옵션의 default 값은 `OnNamespace`. 이건 모든 AlertmanagerConfig sub-route에 `namespace="<config가 위치한 namespace>"` matcher를 자동 prefix하는 동작.

### 3.2 의도

멀티 테넌트 격리:
- A팀 namespace의 AlertmanagerConfig가 B팀 namespace의 알림을 가로채지 못하도록
- 각 namespace의 config는 자기 namespace의 알림만 처리

### 3.3 본 프로젝트에서의 함정

```
배치:
  monitoring namespace의 AlertmanagerConfig
       ↓ (sub-route 정의: severity=critical → slack-critical)
  default namespace의 portfolio-app에서 발생한 알림 (HighErrorRate 등)
       ↓ (Alertmanager 도착)

자동 추가된 matcher: namespace="monitoring"
  ↓
default namespace 알림은 namespace=default라서 매칭 안 됨
  ↓
모든 portfolio-app 알림이 default "null" receiver로 빠짐
  ↓
Slack 미도착 ⚠️
```

### 3.4 1인 프로젝트에서 멀티 테넌트 격리 무관

- 본 프로젝트는 1인 dev 환경 → 다른 팀의 AlertmanagerConfig 없음
- 격리 비활성화로 인한 위험 0

---

## 4. 표준 조치 — matcherStrategy=None 명시

### 4.1 영구 수정 (ADR-0026 박제)

`portfolio-manifests/monitoring/kube-prometheus-stack/values.yaml`:

```yaml
alertmanager:
  alertmanagerSpec:
    alertmanagerConfigMatcherStrategy:
      type: None    # ⭐ 함정 #57 청산
```

### 4.2 적용 명령

```bash
# 1) values.yaml 갱신 후 git commit
cd ~/projects/portfolio-manifests
git add monitoring/kube-prometheus-stack/values.yaml
git commit -m "fix(monitoring): set alertmanagerConfigMatcherStrategy=None

prometheus-operator default(OnNamespace) auto-prefixes
namespace matcher on AlertmanagerConfig sub-routes.

This causes default namespace app alerts to fall through
to the null receiver when AlertmanagerConfig is in monitoring
namespace.

Refs: 함정 #57, ADR-0026"
git push origin main

# 2) ArgoCD가 자동 sync (또는 즉시 트리거)
kubectl patch application kube-prometheus-stack -n argocd \
  --type merge -p '{"operation":{"sync":{}}}'

# 3) Alertmanager Pod 재생성 자동 (config 갱신 감지)
# 또는 강제:
kubectl rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager -n monitoring

# 4) ~30초 대기 후 검증 (Step 5 명령 다시)
```

### 4.3 검증 — runtime config의 namespace prefix 사라짐

```bash
kubectl exec -n monitoring -it alertmanager-kube-prometheus-stack-alertmanager-0 \
  -c alertmanager -- wget -qO- http://localhost:9093/api/v2/status \
  | jq -r '.config.original' | grep -A 10 "route:"
```

기대 — `namespace="monitoring"` matcher 사라짐:

```yaml
route:
  receiver: "null"
  routes:
    - receiver: monitoring/portfolio-alertmanager-config/slack-default
      group_by: [alertname, application]
      routes:    ← namespace prefix 없음
        - matchers: [severity="critical"]
          receiver: ...slack-critical
        - matchers: [severity="warning"]
          receiver: ...slack-warning
```

### 4.4 검증 — 강제 알림 주입

```bash
kubectl exec -n monitoring -it alertmanager-kube-prometheus-stack-alertmanager-0 \
  -c alertmanager -- amtool alert add TestAlert \
  severity=warning team=portfolio \
  --alertmanager.url=http://localhost:9093

# 30초 대기
sleep 30

# Alertmanager 라우팅 확인
kubectl exec -n monitoring -it alertmanager-kube-prometheus-stack-alertmanager-0 \
  -c alertmanager -- wget -qO- http://localhost:9093/api/v2/alerts \
  | jq '.[] | select(.labels.alertname=="TestAlert") | .receivers'
```

**기대**: `[{"name": "monitoring/portfolio-alertmanager-config/slack-warning"}]`

Slack `#ops-alert` 채널 확인 → 알림 메시지 도착 ✅

---

## 5. Trade-off 박제 (운영 환경 진화 경로)

### 5.1 type=None의 한계

운영 환경 (여러 팀의 namespace 공존) 진입 시:
- 다른 팀의 AlertmanagerConfig가 우리 알림을 가로챌 가능성
- 1인 프로젝트의 1순위 결정은 운영 환경엔 부적합

### 5.2 운영 환경의 권장 패턴

옵션 A — **OnNamespace 복귀 + namespace별 config**:
```
default-team/namespace 알림 → default-team의 AlertmanagerConfig
ml-team/namespace 알림 → ml-team의 AlertmanagerConfig
모니터링팀의 monitoring namespace는 시스템 알림만 처리
```

옵션 B — **OnNamespaceExcept**:
```
matcherStrategy:
  type: OnNamespaceExcept
  matcherStrategy:
    excludedNamespaces: [monitoring]
```
monitoring namespace의 config만 모든 namespace 알림 처리, 나머지는 OnNamespace.

옵션 C — **글로벌 config 별도 분리**:
```
alertmanagerConfiguration:
  name: global-alertmanager-config
  global: true
```
namespace에 무관한 글로벌 라우팅을 별도 정의.

운영 환경 진입 시 본 ADR을 supersede할 새 ADR 작성 예정.

---

## 6. 관련 자료

- [metrics-spec.md](../metrics-spec.md) — AlertmanagerConfig 라우팅 표
- [sla.md](../sla.md) — 알림 발화 시 SLO 위반 대응
- [runbook-502-cascade.md](./runbook-502-cascade.md) — 알림이 잘 와도 진짜 사고 진단은 별도
- ADR-0026 (matcherStrategy=None) — 본 사고의 영구 결정 박제
- prometheus-operator 공식: alertmanagerConfigMatcherStrategy
- 함정 #57 (PROJECT_CONTEXT.md) — 본 사고의 박제

---

## 7. 한마디로 정리

> "Phase 4 Epic 7-B 알림 시연에서 PrometheusRule은 발화하는데 Slack 알림 안 오는 사고를 만났습니다. 5단계 진단을 거쳤습니다.
>
> 1. Prometheus의 /api/v1/alerts → 알림 firing 정상 확인
> 2. Alertmanager의 /api/v2/alerts → 받은 알림이 receivers=[null]로 라우팅됨 확인 (사고 신호)
> 3. AlertmanagerConfig label `release: kube-prometheus-stack` 박제됨 확인
> 4. Slack webhook URL 직접 호출 → 'ok' 응답 정상
> 5. Alertmanager runtime config의 /api/v2/status → sub-route에 'matchers: namespace=\"monitoring\"' 자동 추가 발견 ⭐
>
> 진짜 원인은 prometheus-operator의 default `matcherStrategy=OnNamespace`. 멀티 테넌트 격리 의도로 모든 sub-route에 'namespace=<config-ns>' matcher를 자동 prefix하는 동작입니다. monitoring namespace 위치 config가 default namespace 앱 알림을 못 잡았던 것이죠.
>
> 1인 프로젝트라 멀티 테넌트 격리 무관 → values.yaml에 `alertmanagerConfigMatcherStrategy.type=None` 영구 명시. ADR-0026으로 결정 박제했고, 운영 환경 진입 시 namespace별 config로 변경하는 supersede ADR 작성 예정으로도 박제했습니다.
>
> 이게 운영 표준이 아닌 default 동작에 자기 발이 걸리는 사고였고, 5단계 진단으로 좁혀가는 흐름 자체가 면접에서 중요하다고 생각해 본 Runbook으로 박제했습니다."