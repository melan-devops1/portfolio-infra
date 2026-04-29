###############################################################################
# Outputs
#
# 향후 GitHub Actions 워크플로우에서 docker push 대상 URL을 만들 때 사용.
# 예: $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/portfolio/product-service:0.1.0
###############################################################################

output "repository_urls" {
  description = "ECR 리포지토리 URL 맵 (key=리포 이름, value=URL)"
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "repository_arns" {
  description = "ECR 리포지토리 ARN 맵"
  value       = { for k, v in aws_ecr_repository.this : k => v.arn }
}

output "registry_id" {
  description = "ECR 레지스트리 ID (= AWS 계정 ID). docker login 시 사용."
  value = length(aws_ecr_repository.this) > 0 ? (
    values(aws_ecr_repository.this)[0].registry_id
  ) : null
}
