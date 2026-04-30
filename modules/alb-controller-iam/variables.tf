variable "cluster_name" {
  description = "EKS 클러스터 이름 (Pod Identity Association 대상)"
  type        = string
}

variable "namespace" {
  description = "ALB Controller가 배포될 namespace"
  type        = string
  default     = "kube-system"
}

variable "service_account_name" {
  description = "ALB Controller의 ServiceAccount 이름"
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "iam_policy_url" {
  description = "AWS Load Balancer Controller 공식 IAM 정책 JSON URL. 버전과 정합 필요."
  type        = string
  # v2.13.1 (2026-04 현재 안정 버전)
  default = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.1/docs/install/iam_policy.json"
}

variable "tags" {
  description = "공통 태그"
  type        = map(string)
  default     = {}
}
