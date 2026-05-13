###############################################################################
# GitHub Actions용 IAM Role: ECR Push (portfolio-app 레포 전용)
#
# 권한: ECR push/pull만 — 좁은 권한 (least privilege)
# 이유:
#   - portfolio-app은 Docker 이미지 빌드해 ECR에 push하는 역할만 함
#   - 다른 AWS 자원에는 손댈 일 없음
#   - 만약 portfolio-app 레포가 침해돼도 피해 범위가 ECR로 한정
#
# 트러스트 조건:
#   - portfolio-app 레포에서만 assume 가능
#
# 권한 상세 (ECR push에 필요한 최소):
#   - ecr:GetAuthorizationToken — docker login에 필요한 임시 토큰 발급
#   - ecr:BatchCheckLayerAvailability — 같은 레이어 이미 있는지 확인
#   - ecr:GetDownloadUrlForLayer — pull (이미 있는 base 이미지)
#   - ecr:BatchGetImage — 이미지 manifest 조회
#   - ecr:InitiateLayerUpload, UploadLayerPart, CompleteLayerUpload — 레이어 업로드
#   - ecr:PutImage — 최종 manifest 등록
#
# Resource 한정:
#   - ecr:GetAuthorizationToken은 Resource 지원 안 함 → "*" 필수
#   - 나머지는 우리 계정의 portfolio/* 레포만 허용 (다른 ECR 접근 차단)
###############################################################################

resource "aws_iam_role" "github_actions_ecr" {
  name        = "github-actions-ecr"
  description = "ECR push by GitHub Actions in portfolio-app repo"

  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          # OIDC Provider는 다른 프로젝트가 이미 생성 → data source로 참조 (github_oidc.tf 참조)
          Federated = data.aws_iam_openid_connect_provider.github_actions.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # portfolio-app 레포만 — terraform Role과 trust 분리
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/portfolio-app:*"
          }
        }
      }
    ]
  })

  tags = {
    Name    = "github-actions-ecr"
    Purpose = "ci-cd"
  }
}

# 계정 ID + 리전 (정책 ARN 구성용)
data "aws_caller_identity" "current_for_ecr" {}
data "aws_region" "current_for_ecr" {}

resource "aws_iam_policy" "github_actions_ecr_push" {
  name        = "github-actions-ecr-push"
  description = "ECR push permissions for portfolio-app repos"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # 1) ECR 인증 — Resource는 "*" 필수 (AWS 제약)
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      # 2) 우리 계정의 portfolio/* 리포지토리에만 push/pull 허용
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeImages",
          "ecr:DescribeRepositories"
        ]
        Resource = [
          "arn:aws:ecr:${data.aws_region.current_for_ecr.region}:${data.aws_caller_identity.current_for_ecr.account_id}:repository/portfolio/*"
        ]
      }
    ]
  })

  tags = {
    Name = "github-actions-ecr-push"
  }
}

resource "aws_iam_role_policy_attachment" "github_actions_ecr_push" {
  role       = aws_iam_role.github_actions_ecr.name
  policy_arn = aws_iam_policy.github_actions_ecr_push.arn
}
