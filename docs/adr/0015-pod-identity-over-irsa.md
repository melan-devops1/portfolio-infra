# ADR-0015: EKS Pod Identity 채택 (PROJECT_CONTEXT의 IRSA 결정 supersede)

## Status
Accepted (2026-04-28). PROJECT_CONTEXT.md 백로그 항목 "EKS 클러스터 모듈 (Managed Node
Group + IRSA)"의 IRSA 부분을 supersede한다.

## Context

EKS에서 Pod이 AWS API(S3, RDS, Secrets Manager 등)를 호출하려면 IAM 자격 증명이 필요하다.
정적 access key를 컨테이너에 박아넣지 않고 IAM Role을 임시 자격으로 부여하는 두 가지 방식이
있다.

### IRSA (IAM Roles for Service Accounts) — 2019년 도입
- OIDC provider 기반
- 트러스트 정책: IAM Role이 EKS 클러스터의 OIDC issuer를 신뢰
- 매핑: Kubernetes ServiceAccount의 annotation에 IAM Role ARN을 명시
- 한계:
  - 클러스터마다 OIDC provider 별도 생성 (계정 한도 100개에 빠르게 도달)
  - Role을 새 클러스터에서 쓸 때마다 트러스트 정책 갱신
  - IAM 트러스트 정책 사이즈 한도(2048자)에 도달하면 Role 복제 필요
  - 트러스트 정책 디버깅이 까다로움 ("sts:AssumeRoleWithWebIdentity" 실패 추적이 어렵다)

### EKS Pod Identity — 2023년 12월 re:Invent에서 발표, 2026년 표준
- EKS-managed agent (DaemonSet) 기반
- 트러스트 정책: 단일 EKS service principal `pods.eks.amazonaws.com` 신뢰 (모든 클러스터 공통)
- 매핑: EKS API의 `CreatePodIdentityAssociation`으로 ServiceAccount ↔ Role 연결
- 장점:
  - OIDC provider 불필요 → 계정 한도 부담 해소
  - 한 Role을 여러 클러스터에서 트러스트 정책 변경 없이 재사용
  - 자동 session tag (eks-cluster-arn, kubernetes-namespace 등) → ABAC 정책 가능
  - Terraform 코드가 IRSA 대비 절반 이하

## Decision

EKS Pod Identity를 신규 클러스터의 default 권한 모델로 채택한다.

### 구현 사항
1. EKS 모듈 호출 시 add-on `eks-pod-identity-agent`를 항상 활성화 (`before_compute = true`)
2. 향후 Pod이 AWS 권한 필요할 때마다 `aws_eks_pod_identity_association` 리소스 사용
3. `modules/eks/`는 OIDC provider도 함께 생성한다 (공식 모듈 default). IRSA가 필요한
   기존 add-on(예: VPC CNI)이나 향후 마이그레이션 호환을 위해.
4. PROJECT_CONTEXT.md 백로그의 "Managed Node Group + IRSA" → "Managed Node Group +
   Pod Identity"로 갱신 필요

## Consequences

### 긍정
+ AWS가 명시적으로 신규 클러스터에 권장하는 모델 채택 → 면접에서 "최신 표준 추적" 어필
+ Terraform 코드 단순화 (Role 트러스트 정책 자동 처리)
+ Karpenter, AWS Load Balancer Controller 등 신규 add-on이 Pod Identity 지원 추세
+ ABAC 패턴으로 권한 관리 확장 가능

### 부정
- Fargate에선 동작 안 함 (Pod Identity Agent가 DaemonSet으로 EC2 노드에서만 실행)
  → 향후 Fargate 도입 시 해당 워크로드만 IRSA 사용 (혼용 가능)
- Windows 노드에서 미지원 — 본 프로젝트는 Linux only라 무관

### 운영 영향
- 학습 자료가 IRSA보다 적음 (블로그/StackOverflow는 아직 IRSA 위주)
  → AWS 공식 문서와 EKS 모듈 README가 일차 자료
- Pod Identity Agent 자체가 CrashLoopBackOff 시 모든 워크로드 인증 실패 가능
  → 향후 Phase 4 모니터링에서 우선 알림 대상으로 분류

## Alternatives Considered

### IRSA 유지
- 2019~2025년 표준이라 자료가 많음
- 그러나 신규 클러스터에서 굳이 OIDC 복잡성을 떠안을 이유 없음
- PROJECT_CONTEXT.md 원칙 "현행 표준만 추천"에 위배

### 둘 다 사용
- IRSA + Pod Identity 동시 활성 가능. 운영 환경에서 마이그레이션 중에 흔한 패턴
- 본 프로젝트는 신규 구축이라 한 모델로 통일이 깔끔
- 단, 기존 EKS add-on(VPC CNI 등)이 IRSA 트러스트를 자동 생성할 수 있어 OIDC provider는
  유지

## Future Considerations

### Phase 4 (Observability) 진입 시
다음 컴포넌트들이 AWS 권한이 필요하며, 모두 Pod Identity로 구성:
- Prometheus → CloudWatch metrics export (선택)
- Fluent Bit → CloudWatch Logs export
- AWS Load Balancer Controller → ELB 관리
- External Secrets Operator → Secrets Manager 접근

각 워크로드별 IAM Role + Pod Identity Association을 별도 모듈
(`modules/eks-pod-identity/`)로 분리할지, envs/dev에서 직접 관리할지는 컴포넌트 도입
시점에 재결정.

## References
- AWS 공식 발표 (re:Invent 2023):
  https://aws.amazon.com/blogs/containers/amazon-eks-pod-identity-a-new-way-for-applications-on-eks-to-obtain-iam-credentials/
- 마이그레이션 가이드 (2026):
  https://aws.plainenglish.io/replace-irsa-with-zero-oidc-configuration-amazon-eks-pod-identity-for-simplified-iam-access-d4a7a1797e56
- EKS 모듈 v21 changelog: Pod Identity가 Karpenter sub-module의 default