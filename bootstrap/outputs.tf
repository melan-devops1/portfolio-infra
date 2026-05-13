output "tfstate_bucket_name" {
  description = "Terraform state S3 버킷 이름. envs/*/backend.tf에서 사용."
  value       = aws_s3_bucket.tfstate.id
}

output "aws_region" {
  value = var.aws_region
}

# Note: tfstate_lock_table_name은 ADR-0013에서 제거됨.
#       S3 native locking (use_lockfile)으로 전환되어 DynamoDB 불필요.

###############################################################################
# GitHub Actions OIDC 관련 출력
#
# 사용 예:
#   bootstrap/ 폴더에서 `terraform output -raw github_actions_terraform_role_arn` 실행 →
#   GitHub repo settings → Secrets and variables → Actions → New repository secret →
#     name=AWS_ROLE_TO_ASSUME, value=<위 ARN>
#   .github/workflows/*.yml 에서 ${{ secrets.AWS_ROLE_TO_ASSUME }} 로 사용
###############################################################################

output "github_actions_oidc_provider_arn" {
  description = "GitHub Actions OIDC Provider ARN (다른 프로젝트가 생성한 것을 data source로 참조)"
  value       = data.aws_iam_openid_connect_provider.github_actions.arn
}

output "github_actions_terraform_role_arn" {
  description = "Terraform 실행용 Role ARN — portfolio-infra 레포의 Secrets에 등록"
  value       = aws_iam_role.github_actions_terraform.arn
}

output "github_actions_ecr_role_arn" {
  description = "ECR push용 Role ARN — portfolio-app 레포의 Secrets에 등록"
  value       = aws_iam_role.github_actions_ecr.arn
}