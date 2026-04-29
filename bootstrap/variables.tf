variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2" # 서울
}

variable "project_name" {
  description = "프로젝트 이름 (리소스 prefix로 사용)"
  type        = string
  default     = "portfolio"
}

variable "owner_email" {
  description = "리소스 소유자 이메일 (태그용)"
  type        = string
}

###############################################################################
# GitHub Actions OIDC trust 정책에 사용될 GitHub 조직/사용자명
#
# 본 프로젝트의 GitHub 사용자: melan-devops1
# trust sub 패턴: repo:melan-devops1/<repo>:*
###############################################################################
variable "github_org" {
  description = "GitHub 조직 또는 사용자명 (OIDC trust 정책의 sub 조건에 사용)"
  type        = string
  default     = "melan-devops1"
}
