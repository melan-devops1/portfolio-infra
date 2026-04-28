###############################################################################
# Environment 레벨 출력 — terraform output으로 빠르게 확인 가능
#
# 사용 예:
#   terraform output                       # 전체
#   terraform output -raw vpc_id           # 단일 값을 다른 명령에 파이프
#   terraform output -json | jq '.public_subnet_ids.value'
###############################################################################

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  value = module.vpc.vpc_cidr_block
}

output "public_subnet_ids" {
  value = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}

output "intra_subnet_ids" {
  value = module.vpc.intra_subnet_ids
}

output "nat_public_ips" {
  description = "NAT Gateway의 Public IP — 외부 시스템 화이트리스팅 시 사용"
  value       = module.vpc.nat_public_ips
}

output "availability_zones" {
  value = module.vpc.availability_zones
}
