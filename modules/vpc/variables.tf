###############################################################################
# 입력 변수
#
# 설계 원칙:
# - subnet CIDR을 직접 받지 않고, vpc_cidr + az_count + newbits로
#   cidrsubnet() 함수로 자동 계산한다 → 호출자가 일일이 지정 안 해도 됨
# - 운영 환경(prod/staging)에서 이 모듈을 재사용할 때 CIDR만 바꾸면 동작
###############################################################################

variable "name" {
  description = "VPC 이름 (모든 리소스 prefix로 사용)"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR 블록. EKS 권장: /16 이상으로 충분히 크게 잡을 것."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block (e.g., 10.0.0.0/16)."
  }
}

variable "azs" {
  description = "사용할 가용 영역 목록. 최소 2개 (EKS 요구사항)."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "EKS는 최소 2개의 AZ가 필요합니다."
  }
}

###############################################################################
# NAT Gateway 옵션
#
# single_nat_gateway = true:
#   NAT GW를 1개만 만들고 모든 Private Subnet이 공유.
#   → ~$0.045/h 절감, 단 해당 AZ 장애 시 모든 Pod의 인터넷 outbound 다운
#   → 개발/포트폴리오 환경 권장
#
# single_nat_gateway = false:
#   AZ마다 NAT GW를 만들어 격리. AZ 단위 장애에 강함.
#   → 운영 환경 권장
###############################################################################
variable "single_nat_gateway" {
  description = "true면 NAT GW 1개로 비용 절감, false면 AZ당 1개로 HA 구성."
  type        = bool
  default     = true
}

variable "enable_nat_gateway" {
  description = "NAT Gateway 생성 여부. false면 Private Subnet은 외부 인터넷 불가."
  type        = bool
  default     = true
}

###############################################################################
# DNS — EKS는 둘 다 true 필수
###############################################################################
variable "enable_dns_hostnames" {
  description = "VPC 내 EC2/ENI에 DNS 호스트명 부여. EKS는 true 필수."
  type        = bool
  default     = true
}

variable "enable_dns_support" {
  description = "VPC DNS 해석 활성화. EKS는 true 필수."
  type        = bool
  default     = true
}

###############################################################################
# 공통 태그 — 모든 리소스에 머지된다
#
# EKS/ELB가 자동 발견에 사용하는 특수 태그 (kubernetes.io/role/elb 등) 도
# 호출자가 여기에 추가해 모듈 안에서 한 번에 적용 가능.
###############################################################################
variable "tags" {
  description = "모든 VPC 리소스에 적용할 공통 태그"
  type        = map(string)
  default     = {}
}

variable "public_subnet_tags" {
  description = "Public Subnet에만 추가로 붙일 태그 (예: kubernetes.io/role/elb=1)"
  type        = map(string)
  default     = {}
}

variable "private_subnet_tags" {
  description = "Private Subnet에만 추가로 붙일 태그 (예: kubernetes.io/role/internal-elb=1)"
  type        = map(string)
  default     = {}
}
