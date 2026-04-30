###############################################################################
# Environment 레벨 출력 — terraform output으로 빠르게 확인 가능
#
# 사용 예:
#   terraform output                       # 전체
#   terraform output -raw vpc_id           # 단일 값을 다른 명령에 파이프
#   terraform output -json | jq '.public_subnet_ids.value'
###############################################################################

# ===== VPC =====
output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  value = module.vpc.vpc_cidr_block
}

output "public_subnet_ids" {
  value = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}

output "intra_subnet_ids" {
  value = module.vpc.intra_subnet_ids
}

output "nat_public_ips" {
  description = "NAT Gateway의 Public IP — 외부 시스템 화이트리스팅 시 사용"
  value       = module.vpc.nat_public_ips
}

output "availability_zones" {
  value = module.vpc.availability_zones
}

# ===== EKS =====
output "cluster_name" {
  description = "EKS 클러스터 이름"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API 서버 엔드포인트"
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes 버전"
  value       = module.eks.cluster_version
}

output "configure_kubectl" {
  description = "kubectl을 이 클러스터로 설정하는 명령. terraform apply 후 복사하여 실행."
  value       = module.eks.configure_kubectl
}

# ===== ECR =====
output "ecr_repository_urls" {
  description = "ECR 리포지토리 URL 맵 — docker push 대상"
  value       = module.ecr.repository_urls
}

output "ecr_registry_id" {
  description = "ECR 레지스트리 ID (계정 ID와 동일). docker login 시 사용."
  value       = module.ecr.registry_id
}

# ===== ALB Controller =====
output "alb_controller_iam_role_arn" {
  description = "ALB Controller IAM Role ARN — Helm 설치 시 ServiceAccount annotation 등에 활용 가능"
  value       = module.alb_controller_iam.iam_role_arn
}

output "alb_controller_helm_install_command" {
  description = "ALB Controller Helm 설치 명령 (복사하여 실행)"
  value       = <<-EOT
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update eks
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
      -n ${module.alb_controller_iam.namespace} \
      --set clusterName=${module.eks.cluster_name} \
      --set serviceAccount.create=true \
      --set serviceAccount.name=${module.alb_controller_iam.service_account_name} \
      --set region=${var.aws_region} \
      --set vpcId=${module.vpc.vpc_id} \
      --version 1.14.0
  EOT
}