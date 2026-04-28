###############################################################################
# Outputs — 다른 모듈/스택에서 이 VPC를 참조할 때 사용
#
# 향후 EKS 모듈 호출 시:
#   module "eks" {
#     vpc_id     = module.vpc.vpc_id
#     subnet_ids = module.vpc.private_subnet_ids   # EKS 워커 노드용
#   }
###############################################################################

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "VPC CIDR 블록"
  value       = aws_vpc.this.cidr_block
}

output "vpc_arn" {
  description = "VPC ARN"
  value       = aws_vpc.this.arn
}

###############################################################################
# 서브넷 ID 리스트 — EKS, ALB, RDS 모듈에 그대로 넘긴다
###############################################################################
output "public_subnet_ids" {
  description = "Public Subnet ID 리스트 (ALB, NAT GW 위치)"
  value       = [for s in aws_subnet.public : s.id]
}

output "private_subnet_ids" {
  description = "Private Subnet ID 리스트 (EKS 워커 노드 위치)"
  value       = [for s in aws_subnet.private : s.id]
}

output "intra_subnet_ids" {
  description = "Intra Subnet ID 리스트 (RDS 등 격리 자산)"
  value       = [for s in aws_subnet.intra : s.id]
}

###############################################################################
# 게이트웨이/라우팅 메타정보 — 디버깅, VPC Endpoint 추가 시 활용
###############################################################################
output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.this.id
}

output "nat_gateway_ids" {
  description = "NAT Gateway ID 리스트"
  value       = [for ng in aws_nat_gateway.this : ng.id]
}

output "nat_public_ips" {
  description = "NAT Gateway의 Public IP 리스트 (외부에서 보는 outbound IP)"
  value       = [for eip in aws_eip.nat : eip.public_ip]
}

output "public_route_table_id" {
  description = "Public Route Table ID"
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "Private Route Table ID 리스트"
  value       = [for rt in aws_route_table.private : rt.id]
}

output "intra_route_table_id" {
  description = "Intra Route Table ID"
  value       = aws_route_table.intra.id
}

###############################################################################
# AZ 정보 — 다른 모듈에서 동일한 AZ 순서를 사용해야 할 때
###############################################################################
output "availability_zones" {
  description = "사용 중인 가용 영역 리스트"
  value       = var.azs
}
