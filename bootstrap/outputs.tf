output "tfstate_bucket_name" {
  description = "Terraform state S3 버킷 이름. envs/*/backend.tf에서 사용."
  value       = aws_s3_bucket.tfstate.id
}

output "aws_region" {
  value = var.aws_region
}

# Note: tfstate_lock_table_name은 ADR-0013에서 제거됨.
#       S3 native locking (use_lockfile)으로 전환되어 DynamoDB 불필요.
