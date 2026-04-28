###############################################################################
# Terraform Remote State — bootstrap에서 만든 S3 native locking 사용
#
# 변경 이력:
#   v1: dynamodb_table = "portfolio-tfstate-lock"  (deprecated since TF 1.11)
#   v2: use_lockfile  = true                       (현행 표준, S3 conditional write 기반)
#
# 주의:
#   - 이 backend 블록은 변수 보간(${var.x}) 불가. 하드코딩 필수.
#   - bucket 이름은 bootstrap의 outputs.tf 결과와 정확히 일치해야 함:
#     terraform output -raw tfstate_bucket_name (bootstrap/ 폴더에서 실행)
###############################################################################

terraform {
  backend "s3" {
    bucket       = "portfolio-tfstate-601766312629"
    key          = "envs/dev/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true # S3 native locking (conditional write 기반)
  }
}
