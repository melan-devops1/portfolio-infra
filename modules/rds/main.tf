###############################################################################
# RDS 모듈 — PostgreSQL 15
#
# 결정 (ADR-0023에 박제):
# 1. terraform-aws-modules/rds/aws ~> 6.0 wrapping
#    - alb-controller-iam, ebs-csi-iam와 같은 wrapping 패턴
# 2. PostgreSQL 15 (PROJECT_CONTEXT 박제)
# 3. db.t3.micro (1인 dev 비용 ~$0.017/h)
# 4. Single AZ (운영 환경은 Multi-AZ로 변경)
# 5. intra_subnet 배치 (NAT 없는 private — VPC 모듈에 박제)
# 6. 단일 인스턴스 + 단일 master DB (Phase 4 단순화)
#    - 3개 마이크로서비스가 같은 DB 인스턴스 공유
#    - DB는 init script로 분리하거나, 같은 DB에 schema 분리
#    - 운영 환경은 서비스마다 별도 인스턴스 권장
# 7. Master password는 random_password로 자동 생성
#    - Terraform output으로 노출 (sensitive)
#    - K8s Secret은 envs/dev/main.tf에서 별도 처리 (chicken-and-egg 회피)
# 8. 보안 그룹 — EKS 노드 SG에서 5432 인바운드만 허용
###############################################################################

# ─── 1. Master password ───────────────────────────────────────
resource "random_password" "master" {
  length  = 24
  special = true
  # ! @ # $ ... 같은 일부 특수문자 RDS에서 거부됨
  override_special = "!#$%&*()-_=+[]{}<>?"
}

# ─── 2. RDS Security Group ────────────────────────────────────
resource "aws_security_group" "rds" {
  name_prefix = "${var.identifier}-rds-"
  description = "RDS PostgreSQL — EKS 노드에서만 접근"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = var.allowed_security_group_ids
  }

  # outbound 기본 허용 (RDS는 outbound 거의 안 씀)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.identifier}-rds-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ─── 3. RDS Module (공식) ─────────────────────────────────────
module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  identifier = var.identifier

  # ─── 엔진 ─────────────────────────────────────────────────
  engine               = "postgres"
  engine_version       = var.engine_version
  family               = "postgres15"  # parameter group family
  major_engine_version = "15"          # option group (PostgreSQL은 사실상 미사용)
  instance_class       = var.instance_class
  # ⭐ Auto minor version upgrade — AWS가 보안 패치 자동 적용
  auto_minor_version_upgrade = true

  # ─── 스토리지 ─────────────────────────────────────────────
  allocated_storage     = var.allocated_storage     # 20 GB
  max_allocated_storage = var.max_allocated_storage # 100 GB (autoscaling)
  storage_type          = "gp3"
  storage_encrypted     = true

  # ─── 데이터베이스 ─────────────────────────────────────────
  db_name  = var.db_name        # 단일 master DB (예: portfoliodb)
  username = var.master_username
  password = random_password.master.result
  port     = 5432

  # AWS managed master password 사용 안 함 — random_password로 직접
  manage_master_user_password = false

  # ─── 네트워크 ─────────────────────────────────────────────
  create_db_subnet_group = true
  subnet_ids             = var.subnet_ids   # intra_subnet_ids
  vpc_security_group_ids = [aws_security_group.rds.id]

  publicly_accessible = false

  # ─── 백업 / 유지보수 ──────────────────────────────────────
  backup_retention_period = var.backup_retention_period  # dev 1일
  backup_window           = "03:00-06:00"
  maintenance_window      = "Mon:00:00-Mon:03:00"

  # ─── HA — dev는 Single-AZ ─────────────────────────────────
  multi_az = var.multi_az

  # ─── 모니터링 (dev는 비활성, 비용 절약) ──────────────────
  monitoring_interval = 0  # 0 = disabled
  performance_insights_enabled = false

  # ─── 삭제 보호 (dev는 false — destroy 가능) ──────────────
  deletion_protection = var.deletion_protection
  skip_final_snapshot = var.skip_final_snapshot

  # ─── Logs ─────────────────────────────────────────────────
  enabled_cloudwatch_logs_exports = ["postgresql"]
  cloudwatch_log_group_retention_in_days = 7

  # ─── Parameter Group ──────────────────────────────────────
  # PostgreSQL 15 기본 parameter group 그대로
  create_db_parameter_group = false

  # ─── Tags ─────────────────────────────────────────────────
  tags = var.tags
}
