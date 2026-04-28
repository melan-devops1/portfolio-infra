###############################################################################
# Bootstrap: Terraform State Backend (S3 + DynamoDB)
#
# ⚠️ 이 파일은 "Terraform 자체를 위한 인프라"를 만든다.
# 한 번만 apply하고, 그 후 envs/dev/backend.tf가 여기 만들어진 S3를 참조.
#
# 본 부트스트랩의 state 자체는 로컬에 저장 (다른 데 저장할 곳이 없음 — chicken-and-egg).
# 따라서 backend "s3" 블록은 여기엔 없다.
###############################################################################

terraform {
  required_version = ">= 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"   # 2026-04 기준 최신 메이저
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
###############################################################################
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${var.project_name}-tfstate"
  }
}

# Versioning 활성화 — state 사고 시 이전 버전 복구 가능
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
# DynamoDB Table: Terraform State Lock
#
# 동시에 여러 사람이 terraform apply를 할 때 race condition 방지.
# 한 번에 한 명만 apply 가능하도록 lock 매커니즘 제공.
###############################################################################
resource "aws_dynamodb_table" "tfstate_lock" {
  name         = "${var.project_name}-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"   # 사용량만큼만 과금. 거의 무료 (~$0/월)
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name = "${var.project_name}-tfstate-lock"
  }
}