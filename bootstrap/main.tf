###############################################################################
# Bootstrap: Terraform State Backend (S3 only — DynamoDB 제거)
#
# ⚠️ 이 파일은 "Terraform 자체를 위한 인프라"를 만든다.
# 한 번만 apply하고, 그 후 envs/dev/backend.tf가 여기 만들어진 S3를 참조.
#
# 본 부트스트랩의 state 자체는 로컬에 저장 (다른 데 저장할 곳이 없음 — chicken-and-egg).
# 따라서 backend "s3" 블록은 여기엔 없다.
#
# 변경 이력:
#   v1 (ADR-0011): S3 + DynamoDB Lock
#   v2 (ADR-0013): S3 native locking (use_lockfile) — DynamoDB 제거
#                  Terraform 1.10+ S3 backend의 conditional write 기반 lock 사용
###############################################################################

terraform {
  required_version = ">= 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "portfolio"
      ManagedBy   = "terraform"
      Environment = "shared"
      Component   = "bootstrap"
      Owner       = var.owner_email
    }
  }
}

###############################################################################
# 계정 ID 자동 추출 — S3 버킷 이름의 글로벌 유니크성을 보장하기 위해 사용
###############################################################################
data "aws_caller_identity" "current" {}

###############################################################################
# S3 Bucket: Terraform State 저장소
#
# S3 native locking이 의존하는 핵심 보장:
#   - Strong read-after-write consistency (2020년 12월부터 모든 리전)
#   - Conditional write (If-None-Match 헤더로 lock object 동시 생성 방지)
#
# 이 두 가지 덕분에 별도 lock 서비스(DynamoDB) 없이 S3 안에서 lock 가능.
###############################################################################
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${var.project_name}-tfstate"
  }
}

# Versioning — state 사고 시 이전 버전 복구 가능 + S3 native lock의 권장 설정
#
# use_lockfile = true 로 동작 시 lock 파일이 빈번히 create/delete 되므로
# Versioning이 켜져 있으면 그만큼 버전 객체가 쌓인다. 아래 lifecycle로 정리.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 암호화 — state 파일에 시크릿이 들어갈 수 있어서 필수
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Public access 완전 차단 — 절대 외부에 노출되면 안 되는 파일
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

###############################################################################
# Lifecycle 정책 — lock 파일 버전 누적 방지
#
# use_lockfile = true 동작 메커니즘:
#   1. terraform plan/apply 시작 시  → <key>.tflock 파일 PUT (If-None-Match)
#   2. 작업 종료 시                  → <key>.tflock 파일 DELETE
#
# Versioning이 켜져 있어 DELETE는 실제 삭제가 아닌 delete marker 추가.
# 매 apply마다 .tflock의 새 버전 + delete marker가 누적된다.
# 7일 후 noncurrent version과 expired delete marker 자동 정리.
###############################################################################
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  # versioning이 먼저 활성화돼야 lifecycle이 의미 있음
  depends_on = [aws_s3_bucket_versioning.tfstate]

  rule {
    id     = "expire-noncurrent-lock-versions"
    status = "Enabled"

    # lock 파일에만 적용 (state 본체 버전은 보존)
    filter {
      prefix = ""
    }

    # 비현재 버전은 7일 후 삭제
    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    # 객체가 모두 비현재 버전이 되어 delete marker만 남으면 marker도 자동 정리
    expiration {
      expired_object_delete_marker = true
    }
  }
}
