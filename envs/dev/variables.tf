variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2" # 서울
}

variable "project_name" {
  description = "프로젝트 이름 (모든 리소스 prefix에 사용)"
  type        = string
  default     = "portfolio"
}

variable "environment" {
  description = "환경 이름 (dev/staging/prod)"
  type        = string
  default     = "dev"
}

variable "owner_email" {
  description = "리소스 소유자 이메일 (태그용)"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "사용할 가용 영역 (서울 리전 2-AZ)"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}
