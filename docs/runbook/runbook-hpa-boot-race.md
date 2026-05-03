# Runbook: HPA Scale-up 부팅 Race — 새 Pod 부팅 중 트래픽 라우팅 사고

> 부하 증가로 HPA scale-up 시 **새 Pod이 부팅되는 30~60초 동안 ALB target group에 등록되어 트래픽 받는 race condition** 진단/조치 표준 절차.

- **버전**: 1.0
- **최초 작성**: 2026-05-03
- **사고 사례**: Phase 4 Epic 7-A 부하 시연 (2026-05-01)
- **관련 함정**: #48 (HPA scale-up 부팅 race), #49 (ALB readinessGate 적용 패턴)

---

## 1. 증상

### 1.1 신호
- 부하 증가 시 502 비율 갑자기 상승 (40~80%)
- HPA가 새 Pod 만드는 시점과 502 spike 일치
- Restart 카운트는 낮음 (Pod이 죽지는 않음)

### 1.2 부하 도구로 검증된 증상

```
[1차 부하 — 정상 범위]
Total: 2053 요청 (32 req/s)
Status: 201 (성공) 861, 422 (검증 실패) 39, 502 (Bad Gateway) 1153
   → 502 비율: 56%

[2차 부하 — 더 심해짐]
Total: 4293 요청 (66 req/s)
Status: 201 (성공) 892, 422 39, 502 3355
   → 502 비율: 78%
```

부하가 클수록 HPA가 더 적극적으로 scale-up → race condition 더 자주 발생 → 502 더 심해지는 패턴.

---

## 2. 진단 5단계

### Step 1 — HPA 동작 추이 확인

```bash
# HPA 상태 (TARGETS의 CPU%)
kubectl get hpa
# 예: product-service   Deployment/product-service   cpu: 80%/50%   2   4   3

# HPA 이벤트 (scale-up 시점 박제)
kubectl describe hpa product-service | tail -20
# "ScalingReplicaSet: 3→4 (CPU 50% 초과)" 보이면 scale-up 진행 중
```

### Step 2 — Pod 이벤트의 부팅 실패 흔적

```bash
kubectl get events --sort-by='.lastTimestamp' | tail -30
```

**핵심 패턴 — 진단 확정 신호**:

```
4m57s    ScalingReplicaSet         product-service 3→4 (HPA 트리거)
4m56s    Container Started         new Pod 시작
4m41s    Startup probe failed      "connection refused" (Spring Boot 부팅 중)
4m36s    Startup probe failed      (계속)
4m26s    Startup probe failed      (계속)
4m21s    SuccessfullyReconciled    ALB target group에 추가됨
```

이 패턴이 보이면 **HPA 부팅 race 확정**:

```
[t=0s]   부하 증가 → CPU 50% 초과 → HPA scale-up 트리거
[t=1s]   새 Pod Container Started
[t=2~30s] Spring Boot 부팅 중 (포트 안 열림 → connection refused)
[t=15s]  ALB Controller가 target group에 새 Pod 추가 ⚠️
         (부팅 끝나기 전에 라우팅 시작!)
[t=15~30s] 부팅 안 끝난 Pod에 트래픽 → 502
[t=30s+] 부팅 완료 → 정상화
```

### Step 3 — Pod의 readinessGate 확인

```bash
kubectl get pods -o wide
# READINESS GATES 컬럼 확인
# - "0/1" → readinessGate 박제됐지만 ALB health check 통과 못 함
# - "1/1" → 정상 통과
# - 비어 있음 → readinessGate 미적용 ⚠️ (즉시 §3 적용 필요)
```

```bash
# 더 상세
kubectl describe pod -l app=product-service | grep -A 3 "Readiness Gates"
```

### Step 4 — namespace label 확인

```bash
kubectl get namespace default -o jsonpath='{.metadata.labels}'
# 출력에 "elbv2.k8s.aws/pod-readiness-gate-inject":"enabled" 있어야 정상
```

label 없으면 ALB Controller의 mutating webhook이 새 Pod에 readinessGate 자동 주입 안 됨.

### Step 5 — Spring Boot 부팅 시간 측정

```bash
# 새 Pod의 부팅 로그
kubectl logs <new-pod> --tail=100 | grep -E "Started.*in [0-9]+\.[0-9]+ seconds"
# 예: "Started ProductApplication in 28.456 seconds"
```

**판단**:
- 부팅 30초 이하 → 일반적
- 부팅 60초+ → JVM warm-up 또는 의존성 lazy init 검토 (Phase 5+)

---

## 3. 표준 조치 — ALB readinessGate 자동 주입

### 3.1 작동 원리

AWS Load Balancer Controller의 mutating webhook:
```
namespace label "elbv2.k8s.aws/pod-readiness-gate-inject=enabled"
   ↓
새 Pod 생성 시 webhook이 자동으로 spec.readinessGates 주입
   ↓
ALB target group의 health check 통과 전엔 Pod이 Ready 안 됨
   ↓
트래픽 차단 → 502 발생 안 함
```

### 3.2 적용 명령 (즉시)

```bash
# 1) namespace에 label 박기
kubectl label namespace default \
  elbv2.k8s.aws/pod-readiness-gate-inject=enabled --overwrite

# 2) 기존 Pod 재시작 (새 Pod에만 readinessGate 자동 주입됨)
kubectl rollout restart deployment/product-service
kubectl rollout restart deployment/order-service
kubectl rollout restart deployment/payment-service

# 3) 새 Pod이 다 ready될 때까지 대기 (~1-2분)
kubectl rollout status deployment/product-service
kubectl rollout status deployment/order-service
kubectl rollout status deployment/payment-service

# 4) 검증
kubectl get pods -o wide
# READINESS GATES 컬럼 "1/1" 보이면 정상
```

### 3.3 매 destroy/apply 사이클의 자동화 빚

namespace label은 매 사이클마다 수동 박제 필요. PROJECT_CONTEXT.md 함정 #49 박제 항목:
- portfolio-manifests에 `namespace.yaml`로 박제 검토 (Phase 5+ App-of-Apps 시)
- scripts/post-apply.sh로 일괄 자동화 검토

### 3.4 모든 namespace 일괄 적용

운영 환경에선 다음 namespace 모두 label 필요:

```bash
for ns in default monitoring logging tracing; do
  kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace $ns \
    elbv2.k8s.aws/pod-readiness-gate-inject=enabled --overwrite
done
```

---

## 4. 보조 조치 (readinessGate만으로 부족한 경우)

### 4.1 Startup Probe 더 관대하게

`apps/<service>/base/deployment.yaml`:

```yaml
startupProbe:
  httpGet:
    path: /actuator/health/liveness
    port: http
  initialDelaySeconds: 10
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 60   # 30 → 60 (Spring Boot 부팅 5분까지 허용)
```

### 4.2 preStop hook + terminationGracePeriodSeconds

종료 시점에 ALB deregister 시간 확보:

```yaml
spec:
  terminationGracePeriodSeconds: 35
  containers:
    - lifecycle:
        preStop:
          exec:
            command: ["/bin/sh", "-c", "sleep 25"]
```

ALB target group의 deregistration_delay (default 30s) 동안 in-flight 요청 처리 후 종료.

### 4.3 Spring Boot 부팅 시간 단축 (장기, Phase 5+)

| 옵션 | 효과 | 비용 |
|---|---|---|
| **AOT 컴파일** (Spring Boot 3 native image) | 부팅 0.1초까지 단축 | 빌드 시간 + 메모리 패턴 변화 |
| **JVM warm-up** | 첫 요청 latency 안정 | 부팅 시간 자체는 비슷 |
| **Lazy initialization** | 부팅 50% 단축 | 첫 요청 시 latency spike |

본 단계엔 readinessGate가 정답. 부팅 단축은 운영 환경 진입 시 검토.

---

## 5. 검증 — 적용 후 다시 부하

```bash
# 부하 도구로 검증
APP_URL=$(kubectl get ingress portfolio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
hey -z 60s -c 50 -m POST -T application/json \
  -d '{"productId":1,"quantity":1}' \
  http://$APP_URL/api/orders
```

### 기대 결과
- 502 비율 0~5% (Chaos 422는 별도)
- 부하 동안 새 Pod 만들어져도 502 발화 안 함

### 만약 502가 100%로 더 심해진다면
**다른 사고와 cascade 발생**. 다음 Runbook 참조:
- [runbook-502-cascade.md](./runbook-502-cascade.md) — H2 휘발 사고 등

실제 사례에서 readinessGate 적용 후 502가 100%로 더 심해진 사고가 있었음. 진짜 원인은 H2 휘발이었고 ADR-0023 RDS 도입으로 청산.

---

## 6. 운영 환경 진화 경로 (Phase 5+)

### 6.1 운영 자원 증설
- HPA `minReplicas` 상향 (2 → 3) — 부하 증가 시 race 영향 분산
- Pod resources 상향 — JVM warm-up 안정성

### 6.2 Service Mesh 도입
Istio sidecar의 trafficPolicy로 ramp-up 패턴 적용:
- 새 Pod 트래픽 비율 점진 증가 (10% → 50% → 100%)
- canary deploy 패턴과 정합

### 6.3 Predictive Autoscaling
KEDA + 시계열 예측으로 부하 도달 전 scale-up:
- 매일 동일 시점에 부하 발생하는 패턴(예: 점심 시간) 사전 대응
- 부팅 race 자체 회피

---

## 7. 관련 자료

- [runbook-502-cascade.md](./runbook-502-cascade.md) — Step 2에서 Connection refused 외 패턴 발견 시
- [metrics-spec.md](../metrics-spec.md) — HPA 트리거 임계치 (CPU 50%)
- ADR-0019 (ALB Controller) — readinessGate 자동 주입 메커니즘
- ADR-0022 (Observability Metrics) — 본 사고의 발견 흐름

---

## 8. 한마디로 정리

> "Phase 4 Epic 7-A 부하 시연에서 502가 78%까지 치솟는 사고를 만났습니다. Chaos 5%로 설명 안 되는 비율이라 진단을 진행했고, Pod 이벤트에서 'Startup probe failed: connection refused'를 발견했습니다.
>
> 진단 결과: HPA가 CPU 50% 초과로 scale-up 트리거 → 새 Pod이 Spring Boot 부팅하는 30초 동안 ALB Controller가 target group에 추가 → 부팅 안 끝난 Pod에 트래픽 → 502 cascade. 이게 단순 '용량 부족'이 아니라 '확장 중 실패' 패턴이었습니다.
>
> 해결은 AWS Load Balancer Controller의 readinessGate 활용. namespace에 `elbv2.k8s.aws/pod-readiness-gate-inject=enabled` label 한 번 박으면 mutating webhook이 모든 새 Pod에 readinessGate 자동 주입해 ALB health check 통과 전엔 Ready 안 되도록. Pod manifest 직접 수정 불필요.
>
> 다만 namespace label은 매 destroy/apply 사이클마다 수동 박제 필요한 자동화 빚 (함정 #49). Phase 5+에 App-of-Apps 패턴이나 scripts/post-apply.sh로 자동화 검토 중입니다."