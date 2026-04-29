# ADR-0011: Terraform State 백엔드 — S3 (versioning, encryption, public block)

## Status
Accepted (2026-04 [검토 필요: 정확한 결정 시점])
**⚠️ Lock 부분은 ADR-0013에 의해 supersede됨**

## Context

Terraform 작업의 상태는 `terraform.tfstate` 파일에 저장된다. 1인 프로젝트라도 다음 사고 방지가 필요:

1. **State 손실 위험**: `tfstate`를 로컬에만 두면 노트북 고장/실수 삭제 시 인프라 추적 불가
2. **다중 환경**: `envs/dev`, `envs/prod`처럼 환경별 state 분리 필요
3. **시크릿 노출**: `tfstate`엔 RDS 비밀번호 등 평문 시크릿이 담길 수 있음 → 암호화 필수
4. **다중 작업자(미래)**: 1인 프로젝트라도 향후 협업 가능성 대비 lock 필요 (이번 단계에선 lock도 다룸)

### 부트스트랩 문제 (chicken-and-egg)
S3 버킷 자체를 Terraform으로 만들어야 한다. 그런데:
- S3 버킷을 만들려면 → state가 필요
- state를 두려면 → S3 버킷이 필요

이 닭-달걀 문제를 어떻게 풀 것인가?

## Decision

**S3 백엔드 채택 + bootstrap만 로컬 state 예외**.

### 1) 백엔드 구조
- **모든 환경 (envs/dev, envs/prod 등)**: S3 백엔드
- **bootstrap/**: 로컬 state (S3 버킷 자체를 만드는 코드라 예외)

### 2) S3 버킷 보안 설정
```hcl
resource "aws_s3_bucket" "tfstate" {
  bucket = "portfolio-tfstate-${aws_account_id}"
}

# 버전 관리 — 실수 시 이전 state로 복구
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

# 서버측 암호화 (AES-256)
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Public 접근 완전 차단
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

### 3) Lock — DynamoDB (⚠️ ADR-0013에 의해 supersede됨)
처음 결정 시 DynamoDB lock 테이블을 함께 만들었으나, **Terraform 1.10+에서
DynamoDB lock이 deprecated** 되어 ADR-0013에서 **S3 native locking (use_lockfile)**로 전환.

본 ADR의 S3 백엔드 자체(versioning, encryption, public block)는 그대로 유효.

### 4) 백엔드 설정 (envs/*/backend.tf)
```hcl
terraform {
  backend "s3" {
    bucket       = "portfolio-tfstate-601766312629"
    key          = "envs/dev/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true   # ADR-0013 적용
  }
}
```

## Consequences

### 긍정
+ State가 클라우드에 안전하게 저장 (3-AZ 복제 + 99.999999999% 내구성)
+ Versioning으로 실수 시 1초 안에 이전 state 복구 가능
+ 암호화로 시크릿 노출 위험 차단
+ Public block으로 외부 접근 완전 차단
+ bootstrap만 로컬 state로 두는 패턴이 chicken-and-egg를 깔끔히 해결
  - bootstrap은 한 번 실행 후 destroy 안 함 (PROJECT_CONTEXT.md 함정 #15)
+ ADR-0013 supersede에도 본 ADR의 S3 핵심 결정은 유효

### 부정
- 첫 부트스트랩이 두 단계 (bootstrap apply → envs/dev init): 학습 곡선
- bootstrap의 로컬 state 파일은 한 번 만들어지면 보호 필요
  - mitigation: bootstrap 실행 머신에서 `.terraform.tfstate*`를 별도 백업

### 면접 답변용 포인트
"Terraform state는 S3 백엔드로 관리하면서 버전 관리, 서버측 암호화, public 접근 차단을
세트로 적용했습니다. S3 버킷 자체를 Terraform으로 만들어야 하는 chicken-and-egg 문제는
bootstrap 폴더만 로컬 state로 두는 예외 처리로 해결했습니다. 처음엔 DynamoDB lock 테이블도
같이 운영했지만, Terraform 1.10에서 native S3 locking이 GA되어 ADR-0013으로 전환했습니다."

## Alternatives Considered

### 로컬 state만 사용
- 가장 단순
- 그러나 노트북 고장 시 인프라 추적 불가
- 거절

### Terraform Cloud (HashiCorp)
- 무료 tier 제공, GUI로 plan/apply 관리
- Run history, policy as code 등 풍부한 기능
- 그러나 외부 SaaS 의존 + 학습 곡선
- 본 프로젝트는 AWS 자체 자원으로 self-contained 우선
- 거절

### GCS 백엔드 (Google Cloud Storage)
- 본 프로젝트가 AWS 중심이라 부적합
- 거절

## References
- Terraform S3 Backend 공식 문서
- AWS S3 보안 베스트 프랙티스
- ADR-0013: S3 native locking으로 lock 부분 supersede
- PROJECT_CONTEXT.md 함정 #15: 부트스트랩 destroy 금지