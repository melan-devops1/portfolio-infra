# ADR-0019: 외부 트래픽 노출 — AWS Load Balancer Controller + ALB + Pod Identity

## Status
Accepted (2026-04-30)

## Context

Phase 3 마무리(4.6)에서 외부 트래픽을 K8s 클러스터로 받기 위한 Ingress 솔루션 선택이 필요.

옵션:
1. **AWS Load Balancer Controller (ALB)**: AWS 네이티브, ALB의 풍부한 기능 활용
2. **Nginx Ingress Controller**: K8s 생태계 표준, 클라우드 무관
3. **Service type=LoadBalancer**: 가장 단순, NLB 자동 생성

추가 결정 항목:
- Controller에 AWS API 권한 부여 방식: Pod Identity (ADR-0015) vs IRSA
- Ingress 라우팅 방식: path-based vs host-based
- Ingress 매니페스트 도구: Kustomize (ADR-0018)
- IAM 자원 위치: bootstrap (영구) vs envs/dev (환경 종속)

## Decision

### 1) Controller: AWS Load Balancer Controller v2.13.1
- ALB의 풍부한 기능 (path/host routing, WAF 통합, target type=ip 등)
- AWS 환경 정합성 — 다른 AWS 서비스와 매끄럽게 통합
- Helm chart `eks/aws-load-balancer-controller` v1.14.0으로 설치 (ADR-0018의 "3rd party는 Helm" 원칙 첫 적용)

### 2) AWS API 인증: Pod Identity Association
ADR-0015의 첫 실전 적용 사례.
- IAM Role 트러스트 정책: `pods.eks.amazonaws.com` service principal만 신뢰
- OIDC Provider 불필요
- 클러스터 재생성 시에도 같은 IAM Role 재사용 가능

### 3) IAM Policy: AWS 공식 정책 동적 다운로드
- `data "http"`로 GitHub의 공식 IAM 정책 JSON을 빌드 시점에 가져옴
- 정책 갱신(예: 새 ALB 기능 추가) 시 코드 변경 없이 다음 apply에서 자동 반영
- URL에 정확한 버전 명시 (`v2.13.1`)로 재현성 확보

### 4) IAM 자원 위치: envs/dev
- ALB Controller IAM은 EKS 클러스터 단위 자원 (클러스터 destroy 시 함께 사라짐)
- bootstrap에 두면 chicken-and-egg 발생 가능 (cluster_name 의존)
- ECR force_delete와 동일 패턴 — EKS와 운명 공유

### 5) 라우팅: path-based
```
ALB → /api/products/* → product-service:8081
    → /api/orders/*   → order-service:8082
    → /api/payments/* → payment-service:8083
```

### 6) Path 일관성: 컨트롤러 매핑 path 그대로 사용
- 옵션: Ingress path를 `/products/*`로 두고 Spring `context-path` 변경 (코드 수정)
- 옵션: Ingress에서 rewrite (ALB rewrite는 제한적)
- **선택**: 컨트롤러의 `@RequestMapping("/api/products")`를 그대로 활용
  → 코드 수정 0, rewrite 0, ALB rule만 작성

### 7) Target Type: IP 모드
- `instance` 모드는 NodePort 경유 → 추가 hop, kube-proxy 부하
- `ip` 모드는 ALB가 Pod IP에 직접 라우팅 → 한 hop 단축
- VPC CNI가 Pod에 VPC IP를 할당하므로 가능 (EKS 표준)

### 8) Ingress Class: `alb`
- Controller가 watch하는 ingressClass
- 다른 Ingress(예: Nginx)와 공존 가능

### 9) ALB Scheme: internet-facing (Phase 3 시연용)
- public subnet에 ALB 배치 (`kubernetes.io/role/elb=1` 태그 자동 활용)
- 운영 환경에선 `internal` + Route53 + CloudFront 조합 권장
- 도메인 없이 ALB DNS 이름으로 즉시 테스트 가능

## Consequences

### 긍정
+ ADR-0015 Pod Identity 첫 실전 검증 — 면접 어필 강화
+ ADR-0018 Helm 혼용 원칙 첫 검증 — 자체 앱은 Kustomize, 3rd party(ALB Controller)는 Helm
+ Controller 정책이 자동 갱신 (URL 기반 동적 fetch)
+ ALB의 풍부한 기능 (헬스체크, WAF, sticky session 등) 활용 가능
+ `target-type=ip`로 hop 단축 → latency 측정에 깔끔

### 부정
- ALB는 시간당 ~$0.0225 + LCU 과금 → destroy 사이클 시 함께 정리해야 비용 통제
- Controller가 죽으면 새 Ingress 생성 불가 — Phase 4 Prometheus로 알림 추가 필요
- Helm 의존성 (Phase 5+에서 ArgoCD로 GitOps화 예정)

### 말로 정리
"외부 트래픽은 AWS Load Balancer Controller로 ALB를 동적 생성합니다.
Controller에 AWS API 권한을 부여하기 위해 IRSA 대신 Pod Identity Association을 사용했고,
이는 ADR-0015에서 박제한 결정의 첫 실전 적용입니다. IAM 정책 자체는 AWS 공식 GitHub의
JSON을 `data \"http\"`로 빌드 시점에 동적으로 가져와, AWS가 정책을 갱신할 때마다 다음
apply에서 자동 반영되도록 했습니다."

## ALB destroy 순서 (함정)

Ingress를 먼저 삭제해야 ALB가 정리됨. EKS destroy 직전에:
```bash
kubectl delete -k infrastructure/ingress    # ALB 삭제
kubectl delete -k apps/all/overlays/dev     # 서비스 삭제
sleep 60                                    # ENI deregister 대기
terraform destroy                           # VPC destroy
```

이 순서를 안 지키면 ENI/SG가 VPC 점유 중이어서 destroy 실패 (PROJECT_CONTEXT.md 함정 #22 사례).

## Alternatives Considered

### Nginx Ingress Controller
- 클라우드 무관, K8s 표준
- ALB의 풍부한 기능(WAF, OIDC 인증, 글로벌 LB) 활용 못함
- 본 프로젝트는 AWS 종속이라 ALB Controller가 우위
- 거절

### Service type=LoadBalancer
- 가장 단순 (Service 정의만으로 자동)
- 서비스마다 별도 LB → 비용 3배
- path-based routing 불가
- 거절

### IRSA (vs Pod Identity)
- ADR-0015에서 거절 결정
- 본 ADR에서 그 결정 그대로 적용
- 거절

### IAM Policy를 Terraform 코드에 직접 박제
- 정책 갱신 시 매번 코드 수정 필요
- AWS가 정책 변경 시 누락 위험
- `data "http"` 동적 fetch가 우위
- 거절

## References
- AWS Load Balancer Controller 공식: https://kubernetes-sigs.github.io/aws-load-balancer-controller/
- Helm chart: https://github.com/aws/eks-charts/tree/master/stable/aws-load-balancer-controller
- ADR-0015: Pod Identity 채택 (본 ADR이 첫 실전 적용)
- ADR-0018: Kustomize/Helm 혼용 원칙 (본 ADR이 Helm 첫 적용)