# Runbook: 502 Cascade — 분산 호출 실패 cascade

> 부하 시연 또는 운영 환경에서 **5xx 비율이 갑자기 높음 (50%+)**일 때 진단/조치 표준 절차.

- **버전**: 1.0
- **최초 작성**: 2026-05-03
- **사고 사례**: Phase 4 Epic 7-A 부하 시연 (2026-05-01)
- **관련 함정**: #28 (in-memory DB Pod 분리), #50 (502 cascade), #48 (HPA scale-up race)
- **관련 ADR**: ADR-0023 (RDS PostgreSQL)

---

## 1. 증상

### 1.1 알림 트리거
- PrometheusRule `HighErrorRate` 발화 (5xx > 5%)
- Slack `#ops-alert`에 critical 알림

### 1.2 사용자 가시 증상
- API 응답 5xx (Bad Gateway, Internal Server Error)
- 분산 호출 체인의 어느 hop에서든 cascade 발생

### 1.3 부하 도구로 검증된 증상 (실제 사례)

```
[부하 명령]
hey -z 60s -c 50 -m POST -T application/json \
  -d '{"productId":1,"quantity":1}' \
  http://$APP_URL/api/orders

[1차 부하 결과]
Total: 2053 요청 (32 req/s)
Status: 201 (성공) 861, 422 (검증 실패) 39, 502 (Bad Gateway) 1153
   → 502 비율: 56% ⚠️

[2차 부하 결과]
Total: 4293 요청 (66 req/s)
Status: 201 (성공) 892, 422 39, 502 3355
   → 502 비율: 78% ⚠️ (심해짐)
```

**Chaos 5%로는 절대 설명 불가능한 비율**. 진짜 인프라 사고.

---

## 2. 진단 5단계

### Step 1 — Pod 상태 확인 (죽은 Pod / Restart 카운트)

```bash
# 1) 현재 Pod 상태
kubectl get pods -o wide

# 2) Restart 카운트 (Pod이 자주 죽고 살아나는지)
kubectl get pods -o custom-columns=\
NAME:.metadata.name,\
RESTARTS:.status.containerStatuses[0].restartCount,\
READY:.status.containerStatuses[0].ready
```

**판단**:
- Restart 카운트 0 + Ready true → Pod은 살아있음. **Pod 자체 사고 아님**
- Restart 5+ 또는 Ready false → Step 4로 (Pod 사고 진단)

### Step 2 — Pod 이벤트 (OOM / crash 흔적)

```bash
kubectl get events --sort-by='.lastTimestamp' | tail -30
```

**찾을 패턴**:
- `OOMKilled` → 메모리 부족 (Pod limits 검토)
- `BackOff` → 이미지 pull 실패 (ECR 권한)
- `Startup probe failed: connection refused` → **HPA scale-up 부팅 race** (Runbook: hpa-boot-race.md 참조)
- `Unhealthy` → readiness/liveness 실패

### Step 3 — HPA 상태 (스케일 진행 중인지)

```bash
kubectl get hpa
kubectl describe hpa product-service
```

**찾을 패턴**:
- TARGETS `cpu: 80%/50%` 등 임계치 초과 → 부하 자체가 큰 상황
- `ScalingReplicaSet` 이벤트 + 새 Pod 부팅 중 → **HPA 부팅 race 가능성** (Runbook: hpa-boot-race.md 참조)

### Step 4 — 분산 호출 chain 로그 추적

가장 중요한 단계. **5xx의 진짜 원인은 보통 한 두 hop 안쪽에 있음**.

```bash
# order-service의 에러 로그 확인 (502는 보통 order에서 변환됨)
kubectl logs deploy/order-service --tail=50 | grep -i "error\|fail\|exception" | tail -20

# 분산 호출의 다운스트림 — product-service / payment-service 로그도
kubectl logs deploy/product-service --tail=50 | grep -i "warn\|error" | tail -10
kubectl logs deploy/payment-service --tail=50 | grep -i "error\|fail" | tail -10
```

**찾을 패턴**:

| 로그 메시지 | 진짜 원인 | 조치 |
|---|---|---|
| `ProductUnavailableException: Product not available: id=X, status=404` | **product-service에 데이터 없음 (H2 휘발 사고)** | Step 5 (실제 사례 §3 참조) |
| `Connection refused` 또는 `Read timed out` | 다운스트림 Pod 부팅 race 또는 죽음 | hpa-boot-race.md Runbook |
| `Circuit breaker open` | 연속 실패 → 회로 차단 | 다운스트림 안정화 후 자동 복구 대기 |
| `JDBC connection pool exhausted` | DB 연결 고갈 | Step 6 (RDS 진단) |

### Step 5 — H2 휘발 사고 (실제 사례)

#### 사고 흐름 재현 (Phase 4 Epic 7-A)

```
1. 첫 번째 부하 전: curl POST /api/products로 상품 등록
   - product-service Pod A의 H2 in-memory에 productId=1 저장
   - Pod B에는 데이터 없음 (H2는 Pod별 독립)

2. 첫 번째 부하: kube-proxy 라운드로빈
   - Pod A로 라우팅된 요청 → 200 (정상)
   - Pod B로 라우팅된 요청 → 404 → order가 502로 변환
   - 502 비율 ~50% (50/50 라운드로빈)

3. rollout restart 시 (예: readinessGate 적용):
   - product-service Pod 재생성 → Pod A의 H2 데이터도 휘발
   - 모든 Pod에 productId=1 없음
   - 502 비율 ~100%
```

#### 진단 명령

```bash
# product-service의 두 Pod이 같은 데이터 보는지 확인
for pod in $(kubectl get pods -l app=product-service -o name); do
  echo "=== $pod ==="
  kubectl exec $pod -- wget -qO- http://localhost:8081/api/products
  echo
done
# Pod별 결과 다르면 → H2 휘발 사고 확정
```

### Step 6 — DB 연결 / RDS 진단 (Phase 4.4 RDS 도입 후)

```bash
# 1) RDS endpoint 응답 확인
kubectl run --rm -it pg-test --image=postgres:15-alpine --restart=Never -- \
  psql "$JDBC_URL?sslmode=disable" -c "SELECT 1"

# 2) JPA connection pool 상태
kubectl exec -it deploy/product-service -- \
  wget -qO- http://localhost:8081/actuator/metrics/hikaricp.connections.active

# 3) Spring Boot health
kubectl exec -it deploy/product-service -- \
  wget -qO- http://localhost:8081/actuator/health
```

**찾을 패턴**:
- `psql 거부` → RDS Security Group / 네트워크
- HikariCP `active >= max` → connection pool 고갈
- `health: DOWN` → 부팅 중 또는 DB 끊김

---

## 3. 실제 사례 — Phase 4 Epic 7-A H2 휘발 cascade

### 3.1 발생 시점
2026-05-01, Phase 4 Epic 7-A의 부하 시연 단계.

### 3.2 흐름

```
[t=0]    Chaos OFF, 부하 시연 시작
[t=15s]  502 0%
[t=30s]  HPA scale-up 트리거 (CPU 50% 초과) → 새 Pod 부팅
[t=45s]  부팅 race로 502 56% 발견 (1차)
[t=60s]  부하 종료
[다음]   readinessGate 적용 (kubectl label namespace 명령)
         + rollout restart 실행
[t+5min] 다시 부하 → 502 100% (예상은 5%)
[t+10min] Pod 로그 확인 → "Product not available: id=1, status=404"
         → H2 휘발 발견 → 함정 #28 재발 확정
```

### 3.3 진단 결론

```
정상 시 흐름 (이상):
  Client → order → product (200) → payment (201) → 응답 201

실제 흐름:
  Client → order → product (404) → ProductUnavailableException → 502
  (이유: rollout restart로 H2 데이터 휘발)
```

### 3.4 영구 청산 (ADR-0023)

**RDS PostgreSQL 도입**:
- modules/rds/ wrapping 모듈 신규
- intra_subnet 격리 배치
- portfolio-app은 prod 프로파일 그대로 (코드 변경 0)
- ConfigMap/Secret kubectl 외부 주입 패턴

### 3.5 청산 검증 (Phase 3.4)

```
[부하 결과 — RDS 도입 후]
[201] 1121  (성공)
[422] 45    (Chaos 의도)
[502] 0     (인프라 사고 0)
```

H2 휘발 사고 영구 해결. 함정 #28 + #50 청산.

---

## 4. 표준 조치 (Decision Tree)

### 4.1 H2 휘발 사고 (실제 사례 §3)
```
조치: RDS 도입 (영구 해결, ADR-0023 박제됨)
임시: replicas=1로 줄여 단일 Pod에 데이터 집중 (시연 임시 회피만)
```

### 4.2 HPA 부팅 race (Step 2의 Startup probe failed)
```
조치: hpa-boot-race.md Runbook 참조
영구 해결: ALB readinessGate 자동 주입 (namespace label)
```

### 4.3 다운스트림 Pod 죽음 (Step 4의 Connection refused)
```
조치 1: kubectl describe pod <죽은-pod>로 OOM/crash 확인
조치 2: 자원 limits 상향 (memory: 1Gi → 2Gi)
조치 3: Resilience4j circuit breaker 도입 (Phase 5+)
```

### 4.4 DB connection pool 고갈 (Step 6)
```
조치 1: HikariCP maximum-pool-size 검토 (default 10 → 20)
조치 2: 슬로우 쿼리 식별 (Hibernate show-sql + 분석)
조치 3: RDS instance class 상향 (db.t3.micro → db.t3.small)
```

---

## 5. 회고 / 박제 절차

사고 해결 후 반드시:

1. **PROJECT_CONTEXT.md `함정/주의사항` 섹션에 추가**
   - 함정 번호, 증상, 진단 흐름, 해결 박제
2. **portfolio-infra/docs/adr/에 ADR 작성** (영구 결정인 경우)
3. **본 Runbook 갱신** (새 진단 패턴 추가)
4. **PR 머지 후 다음 사이클에서 검증**

---

## 6. 관련 자료

- [metrics-spec.md](../metrics-spec.md) — 5xx 임계치 5%의 정량 근거
- [sla.md](../sla.md) — SLO 위반 시 에러 예산 사용량 계산
- [runbook-hpa-boot-race.md](./runbook-hpa-boot-race.md) — Step 2 부팅 race 발견 시
- ADR-0007 (Chaos 시뮬레이션) — 422 vs 502 분리 의도
- ADR-0023 (RDS) — H2 휘발 영구 청산
- ADR-0026 (matcherStrategy) — Slack 알림 라우팅 보장

---

## 7. 한마디로 정리

> "Phase 4 Epic 7-A의 부하 시연에서 502가 78%까지 치솟는 사고를 만났습니다. Chaos 5%로 설명 안 되는 비율이라 5단계 진단을 진행했고, Pod 이벤트에서 'Startup probe failed: connection refused' 발견 → HPA scale-up 시 새 Pod 부팅 30초 동안 ALB target group에 등록되어 트래픽 받는 race condition이라고 진단했습니다.
>
> ALB Controller의 readinessGate를 namespace label로 자동 주입해 적용한 후 다시 부하 → **502가 100%로 더 심해짐**. 다시 진단해보니 이번엔 rollout restart로 H2 in-memory 데이터가 휘발돼 product-service가 productId=1을 못 찾고 404 cascade로 502 발생. **단일 사고가 아니라 두 가지 함정이 cascade로 발현된 사례**였습니다.
>
> 영구 해결은 ADR-0023의 RDS PostgreSQL 도입. Phase 3.4 검증에서 같은 부하 시나리오에 502가 0으로 완전히 청산됐습니다. 이 모든 흐름을 본 Runbook과 함정 #28/#48/#50으로 박제해 다음 사이클에 같은 사고를 빠르게 진단할 수 있도록 했습니다."