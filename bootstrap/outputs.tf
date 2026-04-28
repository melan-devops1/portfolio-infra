output "tfstate_bucket_name" {
  description = "Terraform state S3 버킷 이름. envs/dev/backend.tf에서 사용."
  value       = aws_s3_bucket.tfstate.id
}

output "tfstate_lock_table_name" {
  description = "Terraform state lock DynamoDB 테이블 이름."
  value       = aws_dynamodb_table.tfstate_lock.name
}

output "aws_region" {
  value = var.aws_region
}