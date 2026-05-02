###############################################################################
# RDS 모듈 — Outputs
#
# Spring Boot가 환경변수로 받을 정보:
#   - DB_URL: jdbc:postgresql://<endpoint>:5432/<dbname>
#   - DB_USERNAME: master_username
#   - DB_PASSWORD: master_password (sensitive!)
###############################################################################

output "db_instance_endpoint" {
  description = "RDS endpoint (host:port)"
  value       = module.db.db_instance_endpoint
}

output "db_instance_address" {
  description = "RDS host (port 제외)"
  value       = module.db.db_instance_address
}

output "db_instance_port" {
  description = "RDS port"
  value       = module.db.db_instance_port
}

output "db_instance_name" {
  description = "초기 DB 이름"
  value       = module.db.db_instance_name
}

output "db_instance_username" {
  description = "Master 사용자명"
  value       = module.db.db_instance_username
}

# JDBC URL 직접 조립 — Spring Boot에 그대로 환경변수로 전달
output "jdbc_url" {
  description = "Spring Boot용 JDBC URL"
  value       = "jdbc:postgresql://${module.db.db_instance_endpoint}/${module.db.db_instance_name}"
}

output "master_password" {
  description = "Master 비밀번호 (sensitive)"
  value       = random_password.master.result
  sensitive   = true
}

output "security_group_id" {
  description = "RDS Security Group ID"
  value       = aws_security_group.rds.id
}
