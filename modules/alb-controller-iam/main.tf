###############################################################################
# AWS Load Balancer Controller IAM 자원
#
# Pod Identity Association으로 ALB Controller Pod에 AWS API 권한 부여.
# ADR-0015 (Pod Identity 채택)의 첫 실전 적용 사례.
#
# 자원 구성:
#   1. IAM Policy — AWS 공식 정책 JSON을 동적으로 가져와 등록
#   2. IAM Role — pods.eks.amazonaws.com을 trust principal로 (IRSA의 OIDC 불필요)
#   3. Policy Attachment
#   4. Pod Identity Association — ServiceAccount ↔ IAM Role 매핑
#
# 주의: ServiceAccount 자체는 Helm으로 ALB Controller 설치 시 생성.
#       이 모듈은 IAM 측 자원만 만든다.
###############################################################################

# 공식 IAM 정책 JSON을 동적으로 가져오기 (정책 갱신 시 코드 변경 불필요)
data "http" "alb_controller_iam_policy" {
  url = var.iam_policy_url

  request_headers = {
    Accept = "application/json"
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "AWS Load Balancer Controller IAM 정책을 가져오지 못했습니다 (HTTP ${self.status_code})."
    }
  }
}

# IAM Policy
resource "aws_iam_policy" "alb_controller" {
  name        = "AWSLoadBalancerControllerIAMPolicy-${var.cluster_name}"
  description = "AWS Load Balancer Controller for ${var.cluster_name}"
  policy      = data.http.alb_controller_iam_policy.response_body

  tags = merge(var.tags, {
    Name = "alb-controller-${var.cluster_name}"
  })
}

# IAM Role — Pod Identity trust principal
resource "aws_iam_role" "alb_controller" {
  name        = "AmazonEKSLoadBalancerControllerRole-${var.cluster_name}"
  description = "Role for AWS Load Balancer Controller via Pod Identity"

  # Pod Identity는 OIDC 대신 EKS service principal만 신뢰하면 됨 (ADR-0015)
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "alb-controller-role-${var.cluster_name}"
  })
}

# Policy Attachment
resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# Pod Identity Association — Helm으로 설치될 ServiceAccount와 매핑
resource "aws_eks_pod_identity_association" "alb_controller" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account_name
  role_arn        = aws_iam_role.alb_controller.arn

  tags = merge(var.tags, {
    Name = "alb-controller-pia-${var.cluster_name}"
  })
}
