###############################################################################
# GitHub Actions용 IAM Role: Terraform 실행 (portfolio-infra 레포 전용)
#
# 권한: AdministratorAccess
# 이유:
#   - Terraform은 VPC, EKS, IAM, S3, KMS, CloudWatch, ECR 등 거의 모든 AWS 자원을 만짐
#   - Phase 2~6에서 자원 종류가 계속 늘어나는데 권한을 매번 갱신하기 비효율적
#   - 대신 trust 조건을 portfolio-infra:* 로 한정하여 다른 레포는 못 빌리게 차단
#
# 세부이유:
#   GitHub Actions Role은 광범위 권한이 필요해 admin을 부여했지만, OIDC trust 정책으로
#   특정 레포(repo:melan-devops1/portfolio-infra:*)만 이 Role을 assume할 수 있게 제한했습니다.
#   레포가 침해돼도 GitHub OIDC 토큰의 sub 클레임이 일치하지 않으면 AWS가 거부합니다.
#
# 운영 환경 강화 옵션 (Phase 6+ 도입 검토):
#   - admin 대신 PowerUser + 필요한 IAM 권한만 별도 추가
#   - Permissions Boundary로 권한 상한선 박제
#   - 브랜치 제한 (refs/heads/main 만)
###############################################################################

resource "aws_iam_role" "github_actions_terraform" {
  name        = "github-actions-terraform"
  description = "Terraform apply by GitHub Actions in portfolio-infra repo"

  # 최대 세션 길이: 1시간 (Terraform apply가 보통 10~15분, 여유 둠)
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # Audience 검증: GitHub Actions가 발급한 토큰의 aud 필드
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # Subject 검증: 어느 레포의 어느 워크플로우인지
            # repo:<org>/<repo>:* 패턴 — 모든 브랜치/PR/태그 허용
            # 운영 환경에서는 :ref:refs/heads/main 식으로 제한 강화 가능
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/portfolio-infra:*"
          }
        }
      }
    ]
  })

  tags = {
    Name    = "github-actions-terraform"
    Purpose = "ci-cd"
  }
}

# Terraform이 다양한 AWS 자원을 만들기 위해 Admin 부여 (trust 조건으로 사용처 한정)
resource "aws_iam_role_policy_attachment" "github_actions_terraform_admin" {
  role       = aws_iam_role.github_actions_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
