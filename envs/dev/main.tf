###############################################################################
# AWS Provider
#
# default_tags는 이 provider로 생성되는 모든 리소스에 자동 부착된다.
# 일관된 태깅 정책 → 비용 추적, 자원 검색, IAM 정책 적용 모두 용이.
###############################################################################

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner_email
    }
  }
}

###############################################################################
# VPC 모듈 호출 — Phase 2.2
#
# 향후 EKS를 만들 때 이 모듈의 outputs을 그대로 EKS 모듈로 넘긴다:
#   module "eks" {
#     vpc_id     = module.vpc.vpc_id
#     subnet_ids = module.vpc.private_subnet_ids
#   }
###############################################################################

module "vpc" {
  source = "../../modules/vpc"

  name     = "${var.project_name}-${var.environment}"
  vpc_cidr = var.vpc_cidr
  azs      = var.azs

  # NAT Gateway: 단일 NAT (비용 절감)
  enable_nat_gateway = true
  single_nat_gateway = true

  # EKS는 DNS 두 옵션 모두 필수
  enable_dns_hostnames = true
  enable_dns_support   = true

  # 향후 EKS 모듈에서 자동 발견용 태그
  # ALB Controller가 Public Subnet에 인터넷용 LB를 띄울 수 있게 표시
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  # ALB Controller가 Private Subnet에 내부용 LB를 띄울 수 있게 표시
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = {
    Component = "network"
  }
}

###############################################################################
# EKS 모듈 호출 — Phase 2.3
#
# 노드는 Private subnet에, Control Plane ENI도 Private subnet에 배치.
# Public 서브넷은 ALB와 NAT만.
###############################################################################

module "eks" {
  source = "../../modules/eks"

  cluster_name       = "${var.project_name}-${var.environment}"
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  # 포트폴리오 환경 — kubectl 편의를 위해 public endpoint 활성화.
  # 운영 환경에선 endpoint_public_access_cidrs를 회사 IP 화이트리스트로 제한 권장.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = ["0.0.0.0/0"]

  # 노드 그룹: t3.large × 2 (HPA로 최대 4까지 확장)
  node_instance_types = ["t3.large"]
  node_capacity_type  = "ON_DEMAND"
  node_min_size       = 2
  node_max_size       = 4
  node_desired_size   = 2
  node_disk_size_gb   = 30

  enable_cluster_creator_admin_permissions = true

  tags = {
    Component = "compute"
  }
}