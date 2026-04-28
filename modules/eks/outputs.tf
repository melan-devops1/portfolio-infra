###############################################################################
# Outputs
#
# 향후 envs/dev/main.tf에서 EKS 위에 ECR/ALB/Pod Identity association 등을
# 추가할 때 이 outputs들을 참조하게 된다.
###############################################################################

output "cluster_name" {
  description = "EKS 클러스터 이름. kubectl 설정 시 사용."
  value       = module.eks.cluster_name
}

output "cluster_arn" {
  description = "EKS 클러스터 ARN"
  value       = module.eks.cluster_arn
}

output "cluster_endpoint" {
  description = "EKS API 서버 엔드포인트"
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "EKS Kubernetes 버전"
  value       = module.eks.cluster_version
}

output "cluster_certificate_authority_data" {
  description = "Base64 인코딩된 클러스터 CA 인증서 (kubeconfig용)"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "EKS가 자동 생성한 클러스터 보안그룹 ID"
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "노드 그룹 보안그룹 ID. 추가 ingress rule 필요 시 참조."
  value       = module.eks.node_security_group_id
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN (Pod Identity 사용 시 직접 참조 불필요, 호환용)"
  value       = module.eks.oidc_provider_arn
}

###############################################################################
# 노드 그룹 정보 — Cluster Autoscaler/Karpenter 등에서 사용
###############################################################################
output "eks_managed_node_groups" {
  description = "Managed Node Group 정보 맵"
  value       = module.eks.eks_managed_node_groups
}

###############################################################################
# kubectl 설정 명령 — 출력 후 바로 복사해서 실행 가능
###############################################################################
output "configure_kubectl" {
  description = "kubectl이 이 클러스터에 접속하도록 설정하는 명령"
  value = format(
    "aws eks update-kubeconfig --region %s --name %s",
    data.aws_region.current.region,
    module.eks.cluster_name
  )
}

data "aws_region" "current" {}
