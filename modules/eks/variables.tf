###############################################################################
# 입력 변수
#
# 모듈 사용자가 흔히 바꾸는 항목만 노출. 그 외 디테일(addon 버전, log retention 등)은
# main.tf의 default로 두고 호출자가 신경 쓰지 않도록.
###############################################################################

variable "cluster_name" {
  description = "EKS 클러스터 이름. 리소스 prefix와 IAM role 이름에 사용된다."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes 버전. 1.33 권장 (1.34/1.35는 안정성 검증 부족)."
  type        = string
  default     = "1.33"
}

###############################################################################
# 네트워크
#
# vpc_id: 클러스터를 둘 VPC
# subnet_ids: 워커 노드와 ENI가 위치할 서브넷 (Private 권장)
# control_plane_subnet_ids: ENI(EKS hyperplane ENI)가 위치할 서브넷.
#   미지정 시 subnet_ids 사용. Private subnet 2개 이상이 EKS 요구사항.
###############################################################################
variable "vpc_id" {
  description = "EKS가 위치할 VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "워커 노드용 서브넷 ID 리스트 (Private subnet 권장)"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "EKS는 최소 2개 AZ에 걸친 서브넷이 필요합니다."
  }
}

variable "control_plane_subnet_ids" {
  description = "EKS control plane ENI용 서브넷 (보통 Private). 미지정 시 subnet_ids 재사용."
  type        = list(string)
  default     = []
}

###############################################################################
# Endpoint 접근
#
# Public + Private 동시 활성: 포트폴리오에선 kubectl 접속 편의성 위해 권장
# Private only: 운영 환경 권장. VPN/bastion 통한 접속만 허용
###############################################################################
variable "endpoint_public_access" {
  description = "Public endpoint 활성화. true면 인터넷에서 kubectl 접근 가능."
  type        = bool
  default     = true
}

variable "endpoint_public_access_cidrs" {
  description = "Public endpoint 접근 허용 CIDR. 기본값은 인터넷 전체. 운영에선 회사 IP로 제한 권장."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

###############################################################################
# 노드 그룹 설정
#
# AL2023: 1.30+ 신규 클러스터의 default AMI. AL2는 1.32 이후 deprecated 트랙.
# capacity_type:
#   ON_DEMAND  - 안정적, 비싸다
#   SPOT       - 70% 할인, AWS가 회수할 수 있음. 포트폴리오 저장 환경에 가능
###############################################################################
variable "node_instance_types" {
  description = "노드 그룹 EC2 인스턴스 타입 리스트. 첫 항목으로 EBS 사이즈 등이 계산됨."
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND 또는 SPOT"
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type은 ON_DEMAND 또는 SPOT만 허용됩니다."
  }
}

variable "node_min_size" {
  description = "노드 그룹 최소 노드 수"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "노드 그룹 최대 노드 수 (HPA/Cluster Autoscaler가 이 한도까지 늘림)"
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "노드 그룹 시작 시 노드 수"
  type        = number
  default     = 2
}

variable "node_disk_size_gb" {
  description = "노드 root EBS 사이즈(GB). 기본 20GB는 도커 이미지 + 임시 컨테이너 데이터를 고려한 최소값."
  type        = number
  default     = 30
}

###############################################################################
# 클러스터 관리자 권한 (Cluster Access Entry)
#
# v21에서 aws-auth ConfigMap이 제거되고 IAM Access Entry로 대체.
# enable_cluster_creator_admin_permissions = true면 이 Terraform을 실행하는 IAM 사용자/Role이
# 자동으로 cluster-admin 권한을 받는다. 포트폴리오에선 편의를 위해 true.
###############################################################################
variable "enable_cluster_creator_admin_permissions" {
  description = "Terraform 실행 주체에게 cluster-admin 권한 자동 부여"
  type        = bool
  default     = true
}

variable "additional_cluster_admins" {
  description = "추가로 cluster-admin 권한을 부여할 IAM Principal ARN 맵. key=식별자, value=ARN."
  type        = map(string)
  default     = {}
}

###############################################################################
# 태그
###############################################################################
variable "tags" {
  description = "모든 리소스에 적용할 공통 태그"
  type        = map(string)
  default     = {}
}
