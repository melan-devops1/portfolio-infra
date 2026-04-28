variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"   # 서울
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