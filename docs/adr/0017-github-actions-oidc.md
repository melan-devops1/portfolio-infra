# ADR-0017: GitHub Actions ↔ AWS 인증 — OIDC + Role 분리

## Status
Accepted (2026-04-28)

## Context

Phase 3에서 GitHub Actions로 두 가지 자동화를 구성한다:
1. portfolio-app: Docker 이미지 빌드 → ECR push
2. portfolio-infra: Terraform plan/apply → AWS 자원 관리

이 워크플로우들이 AWS API를 호출하려면 자격증명이 필요하다. 옵션:
1. **AWS Access Key를 GitHub Secrets에 저장**: 정적 키 → 유출 시 키 revoke 전까지 무방비
2. **OIDC 페더레이션**: GitHub Actions가 워크플로우 실행 중 동적으로 발급한 단기 토큰을 IAM이 신뢰

또한 두 워크플로우의 권한 범위가 매우 다르다:
- portfolio-app: ECR push만 (좁은 권한)
- portfolio-infra: 거의 모든 AWS 자원 (Admin 수준)

## Decision

### 1) 인증 방식: OIDC 페더레이션
- AWS Access Key 미사용 — GitHub Secrets에 정적 키 저장 안 함
- GitHub Actions가 워크플로우 실행 시 OIDC JWT 발급, AWS STS가 검증 후 임시 자격증명 반환
- 임시 자격증명 수명 ≤ 1시간, 자동 만료

### 2) Role 분리: 2개의 IAM Role
**Role A: `github-actions-ecr`**
- 트러스트 조건: `repo:melan-devops1/portfolio-app:*`
- 권한: ECR push/pull (우리 계정의 `portfolio/*` 리포만)

**Role B: `github-actions-terraform`**
- 트러스트 조건: `repo:melan-devops1/portfolio-infra:*`
- 권한: AdministratorAccess

### 3) OIDC Provider 위치: bootstrap/
OIDC Provider는 AWS 계정당 1개만 필요. 모든 환경(dev/staging/prod)이 공유.
- `bootstrap/`에 두면 매일 destroy 사이클에서 제외 → GitHub Actions가 깨지지 않음
- envs/에 두면 chicken-and-egg (Role 없이는 envs apply 불가)

### 4) 트러스트 정책 sub 패턴: `repo:<org>/<repo>:*`
- `*`는 모든 브랜치, PR, 태그 허용 — 1인 프로젝트라 충분
- 운영 환경은 `:ref:refs/heads/main` 식으로 main 브랜치로 제한 권장

### 5) Thumbprint: 동적 추출
- 정적 thumbprint 박는 옛 패턴 회피
- `data "tls_certificate"`로 GitHub OIDC 엔드포인트의 인증서를 동적 추출
- 2024-12 AWS Go SDK 업데이트 후 thumbprint는 사실상 무시되지만, terraform AWS provider 6.x는
  여전히 빈 리스트를 거부할 수 있어 안전책

## Consequences

### 긍정
+ 정적 자격증명 0개 — GitHub Secrets 유출 시에도 즉시 사용 불가 (OIDC 토큰은 워크플로우 실행 중에만 유효)
+ Role 분리로 권한 최소화 — portfolio-app 침해 시 인프라 영향 차단
+ `kubectl` 명령으로 EKS 접근 시 동일 OIDC 페더레이션 패턴 재사용 가능

### 부정
- Admin 권한 Role은 trust 조건이 핵심 방어선 → repo 이름 변경 시 trust 정책 갱신 필수
  - 잊으면 자동화 깨짐 (다행히 자동화가 안 도는 거지 보안 사고는 아님)
- 첫 부트스트랩 시 콘솔/로컬 자격으로 한 번 apply 필요 (자기 자신을 만들 수는 없음)

### 운영 환경 강화 옵션
- Permissions Boundary 부착으로 Admin 권한의 절대 상한선 박제
- branch 제한 (`refs/heads/main` 만) 적용
- Reusable Workflow로 권한 검증 로직 중앙화

## Alternatives Considered

### Static Access Key
- 가장 단순 구현 가능
- 정적 키 유출 시 인지 어려움 + revoke 전까지 무방비
- AWS, GitHub, 업계 모두 OIDC 강력 권장
- 거절

### 단일 Role (분리 안 함)
- 관리 자원 1개로 단순
- portfolio-app 침해 시 Terraform 권한까지 동시 노출
- 권한 최소화 원칙 위배
- 거절

### EKS Pod Identity 활용
- EKS Pod Identity는 EKS 안의 Pod 전용 — GitHub Actions처럼 EKS 외부 워크로드에는 적용 불가
- 본 ADR과 별개 (ADR-0015 EKS Pod Identity와 영역 다름)

## Future Migration Path

### Phase 6 (운영 환경) 진입 시
- 환경별 Role 분리: `github-actions-terraform-dev`, `github-actions-terraform-prod` 등
- 각 Role은 해당 환경의 자원만 만질 수 있도록 권한 한정
- Permissions Boundary 도입

### 신규 레포 추가 시
- 새 trust 조건을 기존 Role에 추가 또는 새 Role 생성
- 권한 범위에 따라 결정

## References
- GitHub 공식: Configuring OpenID Connect in AWS
  https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services
- AWS Blog: AWS Go SDK thumbprint 업데이트 (2024-12)
- ADR-0010: Trivy 스캔 (CI 워크플로우에서 함께 동작)
- ADR-0016: ECR 전략 (이 OIDC가 push할 대상)