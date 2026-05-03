# 운영 보고서 — 2026-05-01 ~ 2026-05-02 운영 사고 사이클

> Phase 4 Epic 7-A의 부하 시연 사고 → Phase 3.4 RDS 도입 청산까지의 종합 회고.
>
> 본 보고서는 단일 사고 회고가 아닌 **여러 사고가 cascade로 발현된 운영 패턴**의 박제입니다.

- **버전**: 1.0
- **작성일**: 2026-05-03
- **사고 발생**: 2026-05-01 (Phase 4 Epic 7-A 부하 시연)
- **영구 청산**: 2026-05-02 (Phase 3.4 RDS 도입 + 검증)
- **관련 ADR**: ADR-0007, ADR-0019, ADR-0022, ADR-0023, ADR-0026
- **관련 함정**: #28, #48, #49, #50, #57
- **관련 Runbook**: [runbook-502-cascade.md](./runbook/runbook-502-cascade.md), [runbook-hpa-boot-race.md](./runbook/runbook-hpa-boot-race.md), [runbook-alertmanager-no-slack.md](./runbook/runbook-alertmanager-no-slack.md)

---

## 1. 요약 (Executive Summary)

### 1.1 발생한 사고 4건 (시간순)

| 시점 | 사고 | 발현 단계 | 영구 청산 |
|---|---|---|---|
| 2026-05-01 14:00 | HPA scale-up 부팅 race (502 78%) | Phase 4 Epic 7-A | ALB readinessGate (함정 #49) |
| 2026-05-01 15:30 | H2 in-memory 데이터 휘발 (502 100%) | Phase 4 Epic 7-A | RDS PostgreSQL (ADR-0023) |
| 2026-05-02 11:00 | Slack 알림 미도착 | Phase 4 Epic 7-B | matcherStrategy=None (ADR-0026) |
| 2026-05-02 16:00 | Jaeger Service 이름 가정 오류 | Phase 4 Epic 9 | 영구 commit 두 곳 (deployment + ingress) |

### 1.2 핵심 학습

1. **단일 사고가 아닌 cascade**: 첫 사고(부팅 race) 해결 후 두 번째 사고(H2 휘발)가 더 심하게 발현.
2. **default 동작이 함정**: prometheus-operator의 default(`OnNamespace`)가 1인 환경에서 의도와 반대로 작용.
3. **선견지명 박제의 가치**: 함정 #28은 Phase 1에 박제했지만 Phase 4까지 발현 안 함. 박제 자체가 다음 사고 진단을 빠르게 만듦.

### 1.3 정량 결과

| 시점 | 부하 결과 | 평가 |
|---|---|---|
| 2026-05-01 1차 부하 | 502 56% | 사고 발생 |
| 2026-05-01 2차 부하 | 502 78% | 더 심해짐 |
| 2026-05-01 3차 부하 (readinessGate 적용 후) | 502 100% | **다른 사고로 변형** |
| 2026-05-02 RDS 도입 후 부하 | 502 0%, 422 4% | **완전 청산** |

---

## 2. 사고 1 — HPA Scale-up 부팅 Race

### 2.1 시점 / 환경

- 2026-05-01 14:00
- Phase 4 Epic 7-A의 첫 부하 시연
- portfolio-app: replicas=2 (HPA min=2, max=4)
- payment-service Chaos: enabled=true, errorRate=5%, delay 100~2000ms

### 2.2 부하 시연 명령

```bash
hey -z 60s -c 50 -m POST -T application/json \
  -d '{"productId":1,"quantity":1}' \
  http://$APP_URL/api/orders
```

### 2.3 1차 부하 결과
```
Total: 2053 요청 (32 req/s)
Status: 201 (성공) 861, 422 (검증 실패) 39, 502 (Bad Gateway) 1153
   → 502 비율: 56% ⚠️
```

### 2.4 2차 부하 결과 (더 심해짐)
```
Total: 4293 요청 (66 req/s)
Status: 201 (성공) 892, 422 39, 502 3355
   → 502 비율: 78% ⚠️
```

### 2.5 진단 5단계 (실제 흐름)

#### Step 1 — Pod 상태 확인
- 모든 Pod READY 1/1
- Restart 카운트 0
- → "Pod 자체 사고 아님" 확인

#### Step 2 — Pod 이벤트
```
4m57s    ScalingReplicaSet         product-service 3→4 (HPA 트리거)
4m56s    Container Started         new Pod 시작
4m41s    Startup probe failed      "connection refused"
4m36s    Startup probe failed      (계속)
4m26s    Startup probe failed      (계속)
4m21s    SuccessfullyReconciled    ALB target group에 추가됨
```

→ **진단 확정**: HPA 부팅 race condition.

#### Step 3 — 흐름 재현
```
[t=0~30s]   첫 Pod 2개로 부하 처리. CPU 급상승.
[t=30s]     HPA가 "scale-up!" 트리거. 새 Pod 부팅 시작.
[t=30~70s]  새 Pod이 부팅 중인데 ALB target group엔 추가됨.
              → 부팅 안 끝난 Pod에 트래픽 전달 → 502
[t=70s+]    새 Pod이 ready 됨. healthy 회복. 502 줄어듦.
```

부하 클수록 HPA가 적극적으로 scale-up → race 더 자주 발생 → 502 더 심해짐.

### 2.6 조치 — ALB readinessGate

```bash
# namespace label 박기
kubectl label namespace default \
  elbv2.k8s.aws/pod-readiness-gate-inject=enabled --overwrite

# 기존 Pod 재시작 (새 Pod에만 readinessGate 자동 주입)
kubectl rollout restart deployment/product-service deployment/order-service deployment/payment-service

# 검증
kubectl get pods -o wide
# READINESS GATES 컬럼 1/1 확인
```

### 2.7 박제

- 함정 #48: HPA scale-up 부팅 race
- 함정 #49: ALB readinessGate 적용 패턴 (namespace label, 매 사이클 수동)
- Runbook: [runbook-hpa-boot-race.md](./runbook/runbook-hpa-boot-race.md)

---

## 3. 사고 2 — H2 In-Memory 데이터 휘발 (가장 큰 학습)

### 3.1 시점 / 환경

- 2026-05-01 15:30, 사고 1 조치 직후
- readinessGate 적용을 위해 rollout restart 진행
- 다시 부하 시연

### 3.2 3차 부하 결과 (예상 vs 실제)

| 항목 | AI 진단 예측 | 실제 결과 |
|---|---|---|
| 502 비율 | "5% 정도" | **100%** |
| 평가 | "부팅 race 해결" | **다른 사고 발현** |

```
Status code distribution:
  [502] 7907 responses
  [201] 0 responses
  [422] 0 responses
```

단 한 요청도 성공 못 함. AI 진단보다 운영자의 직접 진단이 정답에 더 가까운 사례.

### 3.3 진단 — Pod 로그 직접 확인

```bash
kubectl logs deploy/order-service --tail=50 | grep -i "error\|fail\|exception"
```

핵심 발견:
```
ProductUnavailableException: Product not available: id=1, status=404 NOT_FOUND
  at com.portfolio.order.service.ProductClient.lambda$getProduct$0
```

→ **product-service에 productId=1 데이터 없음 → 404 → order가 502로 변환**.

### 3.4 진짜 원인 — H2 휘발 (함정 #28 재발)

```
1. 첫 부하 전: curl POST /api/products로 productId=1 등록
   - product-service Pod A의 H2에만 저장 (Pod B는 빈 상태)

2. 1차/2차 부하: kube-proxy 라운드로빈
   - Pod A 라우팅 시 정상 200
   - Pod B 라우팅 시 404 → 502 일부

3. readinessGate 적용 위해 rollout restart
   - product-service Pod 재생성 → 모든 H2 데이터 휘발 ⚠️

4. 3차 부하: 모든 Pod에 productId=1 없음
   - 100% 404 cascade → 502 100%
```

### 3.5 함정 #28의 배경 (선견지명 박제)

Phase 1 (2026-04-25)에 PROJECT_CONTEXT.md에 박제된 함정:
> "H2 in-memory DB는 Pod 분리 시 데이터 일관성 없음. Phase 4 RDS 도입 시 해결."

Phase 1엔 단일 Pod 단위 검증이라 발현 안 함. Phase 3 K8s 배포부터 분산 호출 시 일부 발현, Phase 4 부하 시연에서 완전 발현.

### 3.6 영구 청산 — RDS 도입 (ADR-0023)

#### 도입 (2026-05-02 Phase 3.4)

```hcl
module "rds" {
  source = "../../modules/rds"

  identifier  = "${var.project_name}-${var.environment}-db"
  vpc_id      = module.vpc.vpc_id
  subnet_ids  = module.vpc.intra_subnet_ids   # 격리 자산용
  
  allowed_security_group_ids = [
    module.eks.node_security_group_id   # EKS 노드만 5432 인바운드
  ]

  engine_version  = "15.17"
  instance_class  = "db.t3.micro"
  multi_az        = false   # dev
  ...
}
```

#### ConfigMap/Secret 외부 주입 (chicken-and-egg 회피)

```bash
# Terraform output → kubectl 직접 (Git에 평문 박제 안 함)
kubectl create configmap portfolio-db-config \
  --from-literal=DB_URL=$(terraform output -raw rds_jdbc_url) \
  --from-literal=DB_DRIVER=org.postgresql.Driver \
  --from-literal=JPA_DDL_AUTO=update \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic portfolio-db-credentials \
  --from-literal=DB_USERNAME=$(terraform output -raw rds_username) \
  --from-literal=DB_PASSWORD=$(terraform output -raw rds_password) \
  --dry-run=client -o yaml | kubectl apply -f -
```

#### portfolio-app은 prod 프로파일 그대로 (코드 변경 0)

`application.yaml`의 prod 프로파일이 이미 PostgreSQL JDBC URL 받도록 박제됨. 환경변수 주입만 변경.

### 3.7 청산 검증 (2026-05-02 Phase 3.4)

같은 부하 명령 (60초 + 50 동시):
```
[201] 1121  (성공 96%)
[422] 45    (Chaos 의도 4%) ✅
[502] 0     (인프라 사고 0%) ⭐
```

**완전 청산**. 함정 #28 + 함정 #50 박제 영구 해결.

### 3.8 박제

- 함정 #28: in-memory DB Pod 분리 (선견지명 박제 유지, 청산 표시 추가)
- 함정 #50: 502의 진짜 원인은 404 cascade
- ADR-0023: RDS PostgreSQL + ConfigMap/Secret 패턴
- Runbook: [runbook-502-cascade.md](./runbook/runbook-502-cascade.md)

---

## 4. 사고 3 — Slack 알림 미도착

### 4.1 시점 / 환경

- 2026-05-02 11:00 (Phase 4 Epic 7-B)
- PrometheusRule + AlertmanagerConfig 구현 완료
- Slack webhook 발급 + Secret 박제
- 강제 알림 주입으로 라우팅 검증 시작

### 4.2 증상

- Prometheus alerts: firing 정상
- Alertmanager: 받기는 함
- Slack `#ops-alert`: **알림 미도착**

### 4.3 진단 5단계 (요약, 상세는 Runbook)

```
1. Prometheus alerts firing 정상 ✓
2. Alertmanager 받은 알림 → receivers=[null]로 빠짐 ⚠️
3. AlertmanagerConfig label release: kube-prometheus-stack 정상 ✓
4. webhook URL 직접 호출 → "ok" 정상 ✓
5. Alertmanager runtime config → "namespace=monitoring" matcher 자동 추가 발견 ⭐
```

### 4.4 진짜 원인 — matcherStrategy=OnNamespace (default)

prometheus-operator의 default 동작:
```
모든 AlertmanagerConfig sub-route에 다음 matcher 자동 prefix:
  namespace="<config가 위치한 namespace>"
```

의도: 멀티 테넌트 격리 (한 팀의 config가 다른 팀 알림을 가로채지 못하게).

본 프로젝트의 사고:
```
AlertmanagerConfig: monitoring namespace에 위치
  → matcher: namespace="monitoring" 자동 prefix

알림: default namespace에서 발생 (HighErrorRate 등)
  → matcher 매칭 안 됨

결과: 모든 알림 default "null" receiver로 빠짐 → Slack 미도착
```

### 4.5 영구 청산 (ADR-0026)

`monitoring/kube-prometheus-stack/values.yaml`:
```yaml
alertmanager:
  alertmanagerSpec:
    alertmanagerConfigMatcherStrategy:
      type: None
```

### 4.6 검증
- runtime config의 namespace prefix 사라짐 확인
- 강제 알림 주입 (severity=warning) → slack-warning receiver 라우팅 확인 → Slack 캡처 1장 확보

### 4.7 박제

- 함정 #57: matcherStrategy=OnNamespace의 namespace 자동 prefix
- ADR-0026: AlertmanagerConfig matcherStrategy=None
- Runbook: [runbook-alertmanager-no-slack.md](./runbook/runbook-alertmanager-no-slack.md)

---

## 5. 사고 4 — Jaeger Service 이름 가정 오류 (요약)

### 5.1 시점

- 2026-05-02 16:00 (Phase 4 Epic 9)
- Jaeger Helm chart 4.7.0 all-in-one 모드 적용

### 5.2 가정 vs 실제

| 항목 | 가정 (production 모드 기준) | 실제 (all-in-one) |
|---|---|---|
| Service 분리 | jaeger-collector + jaeger-query 분리 | 단일 `jaeger` Service |
| 포트 | 4317 (collector) / 16686 (query) 별도 Service | 모든 포트 단일 Service에 통합 |

### 5.3 영향 — 두 곳에서 같은 함정 발현

1. **deployment.yaml의 OTEL endpoint**:
   ```yaml
   OTEL_EXPORTER_OTLP_ENDPOINT: "http://jaeger-collector.tracing.svc:4317"  ← 사고
   ```
   → 새 Pod에 endpoint 미반영 (앱 로그에 connection 에러 없어 발견 늦음)

2. **jaeger-ingress.yaml의 backend**:
   ```yaml
   backend:
     service:
       name: jaeger-query   ← 사고
   ```
   → Jaeger UI 503으로 발견

### 5.4 영구 수정

- commit 45cb78d: deployment.yaml 3개 OTEL endpoint → `http://jaeger.tracing.svc:4317`
- commit 4d00991: jaeger-ingress.yaml backend → `name: jaeger`, port name `http-query`

### 5.5 박제

- 함정 #54: Jaeger Helm chart 4.7.0 all-in-one은 단일 Service
- 학습: 새 Helm chart 도입 시 `kubectl get svc -n <ns>`로 Service 이름 검증

---

## 6. 종합 학습

### 6.1 사고 cascade의 위험

직전 사고 해결이 다음 사고의 트리거가 될 수 있음:
- readinessGate 적용 → rollout restart → H2 휘발 → 502 100%
- 단일 사고 분석으로 끝내지 말고 **다음 사이클 부하 시연으로 추가 검증** 필요

### 6.2 default 동작에 대한 경계

prometheus-operator처럼 운영 표준 도구도 default가 우리 환경에 부적합할 수 있음:
- 새 도구 도입 시 default 옵션을 **운영 환경 가정 vs 본 환경 정합** 검토
- 옵션의 의도를 ADR로 박제 (단순 "default로 두면 됨"이 아니라 "왜 이 옵션을 선택했는가")

### 6.3 선견지명 박제의 가치

함정 #28 (H2 in-memory)은 Phase 1에 박제. Phase 4까지 1개월간 발현 안 했지만:
- 발현 시 **즉시 진단 가능** (이미 박제된 패턴)
- "AI 진단 vs 운영자 진단" 갈림길에서 운영자가 정답 도달 빠름
- ADR-0023 RDS 도입 정당화의 강력한 근거

### 6.4 한마디로 정리

> "이 4건의 사고는 따로 보면 평범한 운영 이슈지만, 묶어보면 운영 cascade의 표본입니다. **첫 사고(HPA 부팅 race) 해결이 두 번째 사고(H2 휘발)의 트리거**가 됐고, 세 번째 사고(matcherStrategy)는 prometheus-operator의 default 동작이 1인 환경에 부적합한 사례, 네 번째 사고(Jaeger Service 이름)는 chart의 mode 차이를 가정 없이 검증해야 한다는 학습이었습니다.
>
> 모든 사고를 5단계 진단(탐지→알림→분석→조치→회고)으로 처리했고, 각각 ADR + 함정 + Runbook으로 3중 박제했습니다. 다음 사이클에 같은 사고를 만나면 운영자가 5분 안에 진단 가능한 자료가 됐습니다."

---

## 7. 영향 분석

### 7.1 직접 영향
- 부하 시연 사이클 1회 실패 (재시도 필요)
- destroy/apply 1회 추가 소요 (~25분)

### 7.2 간접 학습 가치
- 4개 ADR 신규 작성 (ADR-0023, 0024, 0025, 0026, 0027)
- 4개 함정 박제 (#54, #55, #56, #57)
- 3개 Runbook 작성 (502-cascade, hpa-boot-race, alertmanager-no-slack)
- 1개 운영 보고서 (본 문서)

---

## 8. 다음 사이클 검증 항목

다음 destroy/apply 사이클에 다음 시나리오가 작동하는지 검증:

- [ ] readinessGate가 namespace label 한 번으로 모든 Pod에 자동 주입되는지
- [ ] RDS 도입 후 rollout restart 시 데이터 영속 (502 0%)
- [ ] matcherStrategy=None 적용 후 강제 알림 주입 → Slack 도착
- [ ] Jaeger Service `jaeger` 이름으로 OTLP + Query UI 모두 작동
- [ ] 위 4건의 검증 캡처 1장씩 확보 → 면접 자료

---

## 9. 변경 이력

| 일자 | 변경 | 사유 |
|---|---|---|
| 2026-05-03 | 본 보고서 최초 작성 | 운영 사고 cascade 박제 |