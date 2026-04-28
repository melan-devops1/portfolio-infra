###############################################################################
# 모듈 레벨 버전 제약
#
# terraform-aws-modules/eks/aws v21이 요구하는 provider:
#   - aws  >= 5.73, < 7.0  (우리는 ~> 6.0 사용)
#   - tls  ~> 4.0          (Pod Identity association 시 필요)
#
# tls는 "현재 직접 안 쓰지만 child 모듈이 요구"하는 상황 — 명시적으로 선언.
###############################################################################

terraform {
  required_version = ">= 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
