###############################################################################
# ECR 리포지토리 (서비스마다 1개)
#
# for_each로 N개 리포를 한 번에 만든다.
#
# 각 리포는 다음 설정 공유:
#   - IMMUTABLE 태그
#   - scan_on_push 활성화
#   - AES256 암호화 (default)
#   - 동일 lifecycle 정책
###############################################################################

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name                 = each.value
  image_tag_mutability = var.image_tag_mutability
  force_delete         = var.force_delete # destroy 시 자동으로 이미지 같이 지움

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(var.tags, {
    Name = each.value
  })
}

###############################################################################
# Lifecycle 정책
#
# JSON 정책의 핵심 규칙 2개:
#   priority 1: untagged 이미지 → N일 후 삭제 (빠른 정리)
#   priority 2: tagged 이미지 → 최신 N개만 유지 (롤백 여유)
#
# priority 숫자가 작을수록 먼저 평가. 한 이미지가 어떤 규칙에 매칭되면 거기서 적용 종료.
###############################################################################

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "untagged 이미지 ${var.untagged_days}일 후 삭제"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_days
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "tagged 이미지 최신 ${var.keep_tagged_count}개 유지"
        selection = {
          tagStatus   = "tagged"
          tagPatternList = ["*"] # 모든 태그
          countType   = "imageCountMoreThan"
          countNumber = var.keep_tagged_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
