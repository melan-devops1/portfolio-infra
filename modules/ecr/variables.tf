###############################################################################
# 입력 변수
#
# 한 번 호출로 N개 리포지토리를 만든다 (for_each).
# 모든 리포는 동일 lifecycle/scan/encryption 정책 공유.
###############################################################################

variable "repository_names" {
  description = "ECR 리포지토리 이름 리스트 (예: [\"portfolio/product-service\", ...])"
  type        = list(string)

  validation {
    condition     = length(var.repository_names) > 0
    error_message = "최소 1개 이상의 리포지토리 이름이 필요합니다."
  }
}

###############################################################################
# Image Tag Mutability
#
# IMMUTABLE — 같은 태그 덮어쓰기 불가. 운영 베스트 프랙티스.
# MUTABLE — 같은 태그 덮어쓰기 가능 (예: 'latest'를 매번 바꿈)
#
# 본 프로젝트는 ADR-0016에서 IMMUTABLE 채택 (운영 표준 시연).
###############################################################################
variable "image_tag_mutability" {
  description = "이미지 태그 덮어쓰기 정책. IMMUTABLE 권장."
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability는 MUTABLE 또는 IMMUTABLE만 허용됩니다."
  }
}

###############################################################################
# 보안 스캔
#
# scan_on_push = true → push될 때마다 ECR이 자동으로 OS 패키지 + 라이브러리 취약점 스캔
# Trivy(CI 빌드 시점 스캔)와 함께 다층 방어 구성.
###############################################################################
variable "scan_on_push" {
  description = "이미지 push 시 자동 보안 스캔 수행"
  type        = bool
  default     = true
}

###############################################################################
# Lifecycle 정책
#
# untagged_days: untagged 이미지를 삭제할 기간
#   PR 빌드, 실패한 빌드 등이 untagged로 남는데 빠르게 정리하지 않으면 비용 증가.
#
# keep_tagged_count: 보존할 태그 개수 (최신부터 N개)
#   너무 작으면 긴급 롤백 시 옛 이미지가 없을 수 있음. 10~30이 보편.
###############################################################################
variable "untagged_days" {
  description = "untagged 이미지 자동 삭제 기간(일)"
  type        = number
  default     = 1
}

variable "keep_tagged_count" {
  description = "tagged 이미지 보존 개수 (최신 N개)"
  type        = number
  default     = 10
}

variable "tags" {
  description = "모든 ECR 리포지토리에 적용할 공통 태그"
  type        = map(string)
  default     = {}
}
