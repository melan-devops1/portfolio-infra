###############################################################################
# VPC 본체 + 게이트웨이 + 서브넷(3종) + 라우팅
#
# 토폴로지 (10.0.0.0/16 기준):
#
#   ┌─────────────────────── VPC 10.0.0.0/16 ───────────────────────┐
#   │                                                               │
#   │   AZ-a (ap-northeast-2a)        AZ-c (ap-northeast-2c)        │
#   │   ┌──────────────────────┐       ┌──────────────────────┐     │
#   │   │ Public  10.0.0.0/24  │       │ Public  10.0.1.0/24  │     │
#   │   │  └─ NAT GW (a)       │       │                      │     │
#   │   │  └─ ALB              │       │  └─ ALB              │     │
#   │   │ Private 10.0.16.0/20 │       │ Private 10.0.32.0/20 │     │
#   │   │  └─ EKS Worker Nodes │       │  └─ EKS Worker Nodes │     │
#   │   │  └─ Pods             │       │  └─ Pods             │     │
#   │   │ Intra   10.0.48.0/24 │       │ Intra   10.0.49.0/24 │     │
#   │   │  └─ RDS (격리)       │       │  └─ RDS (격리)       │     │
#   │   └──────────────────────┘       └──────────────────────┘     │
#   │                                                               │
#   └───────────────────────────────────────────────────────────────┘
#
# 서브넷 CIDR 할당 (cidrsubnet 함수)
#   newbits=8  → /24 (Public, Intra용)
#   newbits=4  → /20 (Private용, Pod IP 충분)
###############################################################################

locals {
  # AZ 인덱스 — for_each에서 사용하기 위해 map으로 변환
  az_indexed = {
    for idx, az in var.azs : az => idx
  }

  # 서브넷 CIDR 자동 계산
  # 10.0.0.0/16 + newbits=8, netnum=0,1   → 10.0.0.0/24,  10.0.1.0/24    (Public)
  # 10.0.0.0/16 + newbits=4, netnum=1,2   → 10.0.16.0/20, 10.0.32.0/20   (Private)
  # 10.0.0.0/16 + newbits=8, netnum=48,49 → 10.0.48.0/24, 10.0.49.0/24   (Intra)
  public_subnets = {
    for az, idx in local.az_indexed :
    az => cidrsubnet(var.vpc_cidr, 8, idx) # 0, 1
  }

  private_subnets = {
    for az, idx in local.az_indexed :
    az => cidrsubnet(var.vpc_cidr, 4, idx + 1) # 1, 2 → /20
  }

  intra_subnets = {
    for az, idx in local.az_indexed :
    az => cidrsubnet(var.vpc_cidr, 8, idx + 48) # 48, 49
  }

  # NAT GW가 single이면 첫 번째 AZ에만 만든다
  nat_az = var.single_nat_gateway ? [var.azs[0]] : var.azs
}

###############################################################################
# 1. VPC 본체
###############################################################################
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = var.enable_dns_hostnames
  enable_dns_support   = var.enable_dns_support

  tags = merge(var.tags, {
    Name = var.name
  })
}

###############################################################################
# 2. Internet Gateway — Public Subnet의 외부 통신 출입구
###############################################################################
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-igw"
  })
}

###############################################################################
# 3. Public Subnet — ALB, NAT GW가 위치
#
# map_public_ip_on_launch = true:
#   여기서 EC2를 띄우면 Public IP를 자동 부여.
#   EKS Public 엔드포인트, ALB가 사용.
###############################################################################
resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = merge(
    var.tags,
    var.public_subnet_tags,
    {
      Name = "${var.name}-public-${each.key}"
      Tier = "public"
    }
  )
}

###############################################################################
# 4. Private Subnet — EKS 워커 노드, Pod IP가 위치
#
# 가장 큰 서브넷(/20)으로 잡는 이유:
#   AWS VPC CNI가 Pod마다 VPC IP를 할당하므로 IP 소진이 빠름.
#   AWS EKS Best Practices가 명시적으로 권장.
###############################################################################
resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = merge(
    var.tags,
    var.private_subnet_tags,
    {
      Name = "${var.name}-private-${each.key}"
      Tier = "private"
    }
  )
}

###############################################################################
# 5. Intra Subnet — RDS, 내부 전용 서비스 (인터넷 불가, NAT GW 라우팅 없음)
#
# Private Subnet과 Intra Subnet의 핵심 차이:
#   Private: NAT GW 경유로 outbound 인터넷 가능 (Pod의 외부 API 호출)
#   Intra:   인터넷 outbound 자체가 불가 — 데이터베이스 같은 격리된 자산용
#
# 이번 Phase에선 RDS를 안 써도 미리 만들어두면 향후 Phase에서 즉시 활용 가능.
###############################################################################
resource "aws_subnet" "intra" {
  for_each = local.intra_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-intra-${each.key}"
      Tier = "intra"
    }
  )
}

###############################################################################
# 6. NAT Gateway용 Elastic IP
#   Single NAT면 1개, Multi-AZ면 AZ 수만큼.
###############################################################################
resource "aws_eip" "nat" {
  for_each = var.enable_nat_gateway ? toset(local.nat_az) : toset([])

  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name}-nat-eip-${each.key}"
  })

  # IGW가 먼저 만들어져야 EIP allocation 가능
  depends_on = [aws_internet_gateway.this]
}

###############################################################################
# 7. NAT Gateway — Private Subnet의 outbound 인터넷 게이트웨이
###############################################################################
resource "aws_nat_gateway" "this" {
  for_each = var.enable_nat_gateway ? toset(local.nat_az) : toset([])

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = merge(var.tags, {
    Name = "${var.name}-nat-${each.key}"
  })

  depends_on = [aws_internet_gateway.this]
}

###############################################################################
# 8. 라우팅 테이블 — Public
#
# 0.0.0.0/0 → IGW로 보낸다.
###############################################################################
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, {
    Name = "${var.name}-public-rt"
    Tier = "public"
  })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

###############################################################################
# 9. 라우팅 테이블 — Private
#
# Single NAT일 땐 라우팅 테이블 1개만 만들고 모든 Private 서브넷이 공유.
# Multi-AZ NAT일 땐 AZ당 라우팅 테이블 1개씩 만들어 같은 AZ의 NAT을 가리킨다.
###############################################################################
resource "aws_route_table" "private" {
  for_each = var.enable_nat_gateway ? toset(local.nat_az) : toset(var.azs)

  vpc_id = aws_vpc.this.id

  # NAT GW가 활성일 때만 0.0.0.0/0 라우트 추가
  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[each.key].id
    }
  }

  tags = merge(var.tags, {
    Name = "${var.name}-private-rt-${each.key}"
    Tier = "private"
  })
}

# 각 Private 서브넷을 알맞은 라우팅 테이블에 연결
resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id = each.value.id
  # Single NAT이면 모든 서브넷이 동일한 RT(첫 번째 AZ의 RT) 사용
  # Multi-AZ NAT이면 같은 AZ의 RT 사용
  route_table_id = var.single_nat_gateway ? (
    aws_route_table.private[var.azs[0]].id
    ) : (
    aws_route_table.private[each.key].id
  )
}

###############################################################################
# 10. 라우팅 테이블 — Intra (인터넷 라우트 없음)
#
# 0.0.0.0/0 라우트가 없으므로 외부와 격리된다.
# AZ당 1개씩 만들지만, 동일 라우팅이라 사실상 공유해도 무방.
# 일관성을 위해 AZ별로 분리.
###############################################################################
resource "aws_route_table" "intra" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-intra-rt"
    Tier = "intra"
  })
}

resource "aws_route_table_association" "intra" {
  for_each = aws_subnet.intra

  subnet_id      = each.value.id
  route_table_id = aws_route_table.intra.id
}
