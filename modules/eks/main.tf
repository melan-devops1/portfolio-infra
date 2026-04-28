###############################################################################
# EKS 클러스터 — 공식 모듈 wrapping
#
# 이 모듈은 "공식 terraform-aws-modules/eks/aws v21을 우리 프로젝트 컨벤션에 맞게
# 감싸는" 얇은 래퍼다. 공식 모듈을 직접 envs/dev에서 호출해도 되지만, wrapping을
# 통해:
#   1) 우리만의 default 값(AL2023, Pod Identity, 1.33 등)을 한 곳에서 관리
#   2) 향후 staging/prod 환경 추가 시 같은 default를 자동 상속
#   3) 공식 모듈 메이저 업그레이드(v21 → v22) 시 envs/* 변경 없이 modules/eks만 수정
#
# 자세한 결정 배경: docs/adr/0014-eks-official-module.md
#
# 각 옵션의 의미와 trade-off:
#   - addons.before_compute = true: vpc-cni와 pod-identity-agent는 노드 부팅 전에 설치되어야 함.
#                                    누락 시 v21에서 NodeCreationFailure 자주 발생.
#   - eks_managed_node_groups: AWS-managed Auto Scaling Group으로 노드 라이프사이클 관리.
#                              Self-managed 대비 운영 부담 적고, 면접 어필 충분.
###############################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  # === 클러스터 기본 정보 ===
  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  # === 네트워크 ===
  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids
  control_plane_subnet_ids = length(var.control_plane_subnet_ids) > 0 ? (
    var.control_plane_subnet_ids
  ) : var.subnet_ids

  # === Endpoint 접근 ===
  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs
  endpoint_private_access      = true # 내부 통신은 항상 private 사용

  # === Cluster Access Entry — aws-auth ConfigMap 대체 ===
  # Terraform 실행자가 자동으로 cluster-admin 권한 받음
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions

  # 추가 admin들 — 운영 환경에선 다른 팀원 IAM ARN을 여기에 넣음
  access_entries = {
    for key, principal_arn in var.additional_cluster_admins :
    key => {
      principal_arn = principal_arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  # === EKS Add-ons ===
  # before_compute = true는 노드보다 먼저 add-on이 설치되도록 강제.
  # vpc-cni가 늦으면 노드의 ENI 부착이 깨져 NodeCreationFailure 발생.
  addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
    # aws-ebs-csi-driver는 Phase 4(Observability)에서 PV 필요할 때 추가 예정.
    # 지금 넣으면 사용 안 하는 PVC 컨트롤러가 노드 리소스만 잡아먹음.
  }

  # === Managed Node Group ===
  eks_managed_node_groups = {
    main = {
      # 노드 라벨 — 향후 nodeSelector/affinity로 워크로드 분리 가능
      labels = {
        role = "general"
      }

      # AL2023 — Bottlerocket 대안도 있지만 AL2023이 보편적
      ami_type = "AL2023_x86_64_STANDARD"

      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # 노드 root EBS
      disk_size = var.node_disk_size_gb

      # 디버깅 편의 — 노드에 SSM Session Manager로 접속 가능
      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      tags = merge(var.tags, {
        "k8s.io/cluster-autoscaler/enabled"                 = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}"     = "owned"
      })
    }
  }

  tags = var.tags
}
