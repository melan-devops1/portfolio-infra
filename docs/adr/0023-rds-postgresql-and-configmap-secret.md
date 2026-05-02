# ADR-0023: RDS PostgreSQL + ConfigMap/Secret 패턴 (Phase 4.4)

- 상태: 채택 (Accepted)
- 날짜: 2026-05-02
- 태그: phase-4, rds, configmap, secret, pod-identity, chicken-and-egg

---

## 컨텍스트

Phase 4 Epic 7-A (Prometheus + Grafana 시연) 마무리 단계에서 H2 in-memory DB의
운영 한계가 직접 발현됐다. 함정 #28 (in-memory DB Pod 분리)과 함정 #50 (502 cascade)
이 박제됐고, 부하 시연 시 **502 78~100% 사고**까지 발생했다.

진짜 원인:
- product-service Pod이 rollout restart 시 H2 데이터 휘발
- order-service의 ProductClient가 GET /api/products/1 → 404
- order의 GlobalExceptionHandler가 502로 변환 → cascade
- ALB readinessGate(함정 #49) 적용해도 H2 휘발은 readinessGate로 못 막음

운영 표준 해결: **외부 DB(RDS) 도입 + ConfigMap/Secret 패턴**.

---

## 결정

### 1. RDS PostgreSQL 15 도입

- 엔진: PostgreSQL 15.17 (2026-02-27 출시 최신 minor)
  - PROJECT_CONTEXT 박제: PostgreSQL 15
  - auto_minor_version_upgrade = true (보안 패치 자동 적용)
- 인스턴스: db.t3.micro (1인 dev 비용 ~$0.017/h)
- 스토리지: gp3 20GB → 100GB autoscaling
- 배치: intra_subnet (NAT 없는 격리 자산용 — VPC 모듈 박제)
- HA: Single-AZ (운영은 Multi-AZ로 변경)
- 백업: 1일 보관 (운영은 7일+)
- 보안: EKS 노드 SG에서만 5432 인바운드 허용

### 2. terraform-aws-modules/rds/aws ~> 6.0 wrapping 패턴

`modules/rds/`에서 공식 모듈을 wrapping:
- ADR-0014 (EKS 공식 모듈 wrapping)와 동일 컨벤션
- alb-controller-iam, ebs-csi-iam과 같은 wrapping 일관성
- 우리 default 값(PostgreSQL 15, db.t3.micro, intra_subnet 등) 한 곳에서 관리
- 향후 staging/prod 추가 시 같은 default 자동 상속

### 3. Master password — random_password + Terraform output

```hcl
resource "random_password" "master" {
  length  = 24
  special = true
  override_special = "!#$%&*()-_=+[]{}<>?"
}
```

- Terraform이 24자 password 자동 생성
- Terraform output으로 노출 (sensitive = true)
- AWS managed master password 사용 안 함 (Phase 5+ Secrets Manager 진화 시 검토)

### 4. ConfigMap/Secret 패턴 — Z-안전 (kubectl 외부 주입)

매 destroy/apply 사이클:
```bash
JDBC_URL=$(terraform output -raw rds_jdbc_url)
DB_USER=$(terraform output -raw rds_username)
DB_PASS=$(terraform output -raw rds_password)

kubectl create configmap portfolio-db-config \
  --from-literal=DB_URL=$JDBC_URL \
  --from-literal=DB_DRIVER=org.postgresql.Driver \
  --from-literal=JPA_DDL_AUTO=update \
  --from-literal=JPA_DIALECT=org.hibernate.dialect.PostgreSQLDialect \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic portfolio-db-credentials \
  --from-literal=DB_USERNAME=$DB_USER \
  --from-literal=DB_PASSWORD=$DB_PASS \
  --dry-run=client -o yaml | kubectl apply -f -
```

deployment.yaml에서 envFrom으로 reference:
```yaml
env:
  - name: SPRING_PROFILES_ACTIVE
    value: "prod"
envFrom:
  - configMapRef:
      name: portfolio-db-config
  - secretRef:
      name: portfolio-db-credentials
```

이유:
- chicken-and-egg 회피 (함정 #51 정합 — Hashicorp 공식 권장)
- portfolio-manifests에 평문 password 박제 안 함
- 함정 #44 (EBS CSI), 함정 #49 (namespace label)와 같은 "매 사이클 작업" 패턴
- 운영 일관성

### 5. Spring Boot 프로파일 — prod 활용 (k8s 신설 보류)

PROJECT_CONTEXT 박제:
> "application.yaml에 k8s 프로파일 신설 (JSON 로그 + RDS PostgreSQL)"

근데 logback-spring.xml에 이미 박제:
```xml
<springProfile name="prod,k8s">
  <appender ... LogstashEncoder ... />
</springProfile>
```

prod와 k8s 둘 다 같은 JSON 로그 매핑. application.yaml의 prod 프로파일도 PostgreSQL
정합. 따로 k8s 프로파일 신설 시 portfolio-app 변경 필요(PR + CI 빌드).

**결정: prod 프로파일 그대로 활용**. portfolio-app 변경 0.
Phase 5+ staging/prod 분리 시 진짜 k8s 프로파일 신설 검토.

### 6. 단일 인스턴스 + 단일 master DB

- 3개 마이크로서비스(product/order/payment)가 같은 RDS 인스턴스 + 같은 DB(`portfoliodb`)
- JPA의 ddl-auto: update로 테이블 자동 생성
- 운영 환경은 서비스별 DB 분리 권장 (Phase 5+ 검토)

이유: 1인 dev 비용 의식 + 시연 단순화.

---

## 결과

### 검증된 사고 청산

함정 #28 + #50 영구 청산:
```
Before (H2):
- rollout restart → 데이터 휘발 → 502 cascade
- 부하 시연 502 비율 78~100%

After (RDS):
- rollout restart → 데이터 영속 ⭐
- 부하 시연 502 비율 0% (Chaos만 422로 4%)
```

### Terraform 자원 추가

`modules/rds/` 4개 파일:
- main.tf (random_password, SG, terraform-aws-modules/rds wrapping)
- variables.tf (validation 박제 — subnet_ids ≥ 2)
- outputs.tf (jdbc_url, master_password)
- versions.tf

`envs/dev/`:
- main.tf의 module "rds" 호출 + depends_on=[module.eks]
- outputs.tf의 rds_jdbc_url, rds_username (sensitive), rds_password (sensitive)

### 비용 영향

```
EKS + 노드 + ALB:    ~$0.4/h (기존)
RDS db.t3.micro:     ~$0.017/h (추가)
RDS storage 20GB:    ~$0.0001/h
─────────────────────────
총:                   ~$0.42/h
```

매일 destroy/apply 패턴 유지: Phase 4 진행 시 월 ~$30~40 (Budgets $80 이내).

### 운영 진화 경로

Phase 5+ 운영 표준화 시 검토:
1. Multi-AZ 활성화
2. Secrets Manager + AWS SDK 통합 (Pod이 직접 password 가져옴)
3. ExternalSecrets Operator (K8s Secret 자동 동기화)
4. 서비스별 DB 분리 (productdb, orderdb, paymentdb)
5. RDS Proxy (connection pooling)
6. backup_retention_period 7일+

---

## 박제된 함정

이번 Phase 4.4 작업에서 박제된 함정:

- **함정 #51**: Terraform kubernetes_labels chicken-and-egg
  - 직전 namespace label 자동화 검토 시 박제
  - 이번 ConfigMap/Secret 패턴 결정의 근거
  
- **함정 #52**: AWS Security Group description ASCII-only
  - "RDS PostgreSQL — EKS 노드에서만 접근" (한글 + em dash) 사용 시 거부
  - 영문으로 패치
  
- **함정 #53**: Chaos 시뮬레이션 결과 매핑 — 422 (5xx 아님)
  - PaymentDeclinedException → GlobalExceptionHandler → 422 Unprocessable Entity
  - 부하 시연 결과 해석 시 비즈니스 거절(4xx) vs 진짜 사고(5xx) 명확 구분

함정 청산:
- **함정 #28** ✅ (in-memory DB Pod 분리 — RDS 영속성으로 청산)
- **함정 #44** ✅ (EBS CSI Pod Identity — modules/ebs-csi-iam 박제 마무리)
- **함정 #50** ✅ (H2 휘발 cascade — RDS로 영구 해결)

---

## 말로 정리

> "Phase 4.4에서 H2 in-memory의 운영 한계(함정 #28, #50)를 RDS PostgreSQL 도입으로
> 청산했습니다. 직전 시연(Phase 4 Epic 7-A)에서 만난 502 78~100% 사고가 RDS +
> readinessGate 적용 후 502 0%로 극적 개선됐습니다.
>
> 운영 표준 박제:
> - terraform-aws-modules/rds/aws ~> 6.0 wrapping 패턴 (ADR-0014 정합)
> - intra_subnet 격리 (VPC 모듈 박제 활용)
> - EKS 노드 SG에서만 5432 인바운드
> - random_password로 master 자동 생성 (Terraform output)
> - ConfigMap/Secret은 kubectl 외부 주입 (chicken-and-egg 회피, 함정 #51 정합)
>
> 부하 시연 결과 (stock=100000, 60초):
> - [201] 96% (성공)
> - [422] 4% (Chaos 의도된 거절 — payment의 PaymentDeclinedException)
> - [502] 0% (인프라 사고 0)
>
> 코드 검증으로 PaymentDeclinedException → 422 매핑이 의도적 설계임을 확인.
> '결제 거절'은 비즈니스 거절(4xx)이지 서버 사고(5xx)가 아니라는 운영 표준."

---

## Supersedes / 영향

- 함정 #28 (in-memory DB Pod 분리) ✅ 영구 해결
- 함정 #50 (H2 휘발 cascade) ✅ 영구 해결
- ADR-0014 (EKS 공식 모듈 wrapping) — 같은 wrapping 패턴 정합
- ADR-0015 (Pod Identity) — 네 번째 실전 적용 (RDS는 Phase 5+에 통합)
- ADR-0022 (Observability Metrics) — H2 휘발 사고 박제 → 이번에 청산