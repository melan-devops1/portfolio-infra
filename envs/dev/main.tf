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

###############################################################################
# ECR 모듈 호출 — Phase 2.4
#
# 3개 마이크로서비스용 리포지토리.
# 리포 이름은 portfolio/<service> 패턴 — IAM 정책의 portfolio/* 와 정합.
###############################################################################

module "ecr" {
  source = "../../modules/ecr"

  repository_names = [
    "portfolio/product-service",
    "portfolio/order-service",
    "portfolio/payment-service",
  ]

  image_tag_mutability = "IMMUTABLE"
  scan_on_push         = true
  untagged_days        = 1
  keep_tagged_count    = 10
  force_delete = true   # dev 환경 — destroy 시 이미지 자동 삭제

  tags = {
    Component = "registry"
  }
}

###############################################################################
# AWS Load Balancer Controller IAM — Phase 3.4.6
#
# Pod Identity 기반 (ADR-0015 첫 실전 적용).
# 실제 Controller 설치는 Helm으로 별도 진행 (ADR-0019).
###############################################################################

module "alb_controller_iam" {
  source = "../../modules/alb-controller-iam"

  cluster_name = module.eks.cluster_name

  tags = {
    Component = "ingress"
  }

  depends_on = [module.eks]
}

###############################################################################
# EBS CSI Driver IAM — Phase 4 (함정 #44 박제)
#
# Pod Identity 기반 (ADR-0015 정합).
# 직전 사이클까지는 매 destroy/apply 시 수동 IAM Role + association 생성.
# Phase 4 진입 시점에 Terraform 모듈로 자동화.
###############################################################################

module "ebs_csi_iam" {
  source = "../../modules/ebs-csi-iam"

  cluster_name = module.eks.cluster_name

  tags = {
    Component = "storage"
  }

  depends_on = [module.eks]
}

###############################################################################
# RDS PostgreSQL (Phase 4)
###############################################################################

module "rds" {
  source = "../../modules/rds"

  identifier = "${var.project_name}-${var.environment}-db"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.intra_subnet_ids   # ⭐ 격리 자산용

  # EKS 노드 SG에서만 5432 접근 허용
  allowed_security_group_ids = [
    module.eks.node_security_group_id
  ]

  # dev 설정 (PROJECT_CONTEXT 박제 — 비용 의식)
  engine_version          = "15.17"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  max_allocated_storage   = 100
  db_name                 = "portfoliodb"
  master_username         = "portfolio_admin"
  multi_az                = false
  backup_retention_period = 1
  deletion_protection     = false
  skip_final_snapshot     = true

  tags = {
    Component = "database"
  }

  depends_on = [module.eks]   # ⭐ EKS 노드 SG 참조하니 순서 명시
}