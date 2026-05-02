###############################################################################
# RDS 모듈 — Variables
###############################################################################

variable "identifier" {
  description = "RDS 인스턴스 식별자 (예: portfolio-dev-db)"
  type        = string
}

variable "vpc_id" {
  description = "RDS가 위치할 VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "RDS Subnet Group의 Subnet ID 목록 (intra_subnet_ids 권장)"
  type        = list(string)
  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "RDS Subnet Group은 최소 2개의 AZ에 분포된 subnet 필요."
  }
}

variable "allowed_security_group_ids" {
  description = "RDS 5432 포트 접근 허용 SG 목록 (EKS 노드 SG)"
  type        = list(string)
}

# ─── DB 설정 ──────────────────────────────────────────────────
variable "engine_version" {
  description = "PostgreSQL 버전"
  type        = string
  default     = "15.17"   # 2026-02-27 출시 최신 minor
}

variable "instance_class" {
  description = "RDS 인스턴스 타입"
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "초기 스토리지 (GB)"
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Auto-scaling 최대 (GB)"
  type        = number
  default     = 100
}

variable "db_name" {
  description = "초기 생성 DB 이름"
  type        = string
  default     = "portfoliodb"
}

variable "master_username" {
  description = "Master 사용자명"
  type        = string
  default     = "portfolio_admin"
}

# ─── HA / 백업 ────────────────────────────────────────────────
variable "multi_az" {
  description = "Multi-AZ 여부 (dev=false)"
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "백업 보관 일수 (dev=1)"
  type        = number
  default     = 1
}

variable "deletion_protection" {
  description = "삭제 보호 (dev=false, prod=true)"
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "destroy 시 최종 스냅샷 스킵 (dev=true)"
  type        = bool
  default     = true
}

variable "tags" {
  description = "공통 태그"
  type        = map(string)
  default     = {}
}
