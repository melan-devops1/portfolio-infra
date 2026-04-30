output "iam_role_arn" {
  description = "ALB Controller가 사용할 IAM Role ARN"
  value       = aws_iam_role.alb_controller.arn
}

output "iam_role_name" {
  description = "ALB Controller IAM Role 이름"
  value       = aws_iam_role.alb_controller.name
}

output "service_account_name" {
  description = "Helm 설치 시 사용할 ServiceAccount 이름"
  value       = var.service_account_name
}

output "namespace" {
  description = "Helm 설치 대상 namespace"
  value       = var.namespace
}
