# ADR-0012: VPC 네트워크 설계 (직접 작성 + 단일 NAT GW)

## Status
Accepted (2026-04-28)

## Context

Phase 2의 첫 본격 인프라 모듈로 VPC를 작성해야 한다. 다음 두 가지 큰 결정이 필요했다.

1. **공식 모듈(`terraform-aws-modules/vpc/aws` v6.x) 사용 vs 직접 작성**
2. **NAT Gateway: 단일 NAT vs Multi-AZ NAT**

본 프로젝트는 DevOps 엔지니어 포트폴리오로, 학습 가치와 운영 효율 사이의 균형이 핵심이다.
또한 PROJECT_CONTEXT.md에 명시된 비용 제약(월 $30~40, Budgets $50)도 결정에 영향을 준다.

## Decision

### 1) VPC 모듈은 직접 작성한다 (하이브리드 전략)

`modules/vpc/`에 VPC, Subnet 3종(Public/Private/Intra), IGW, NAT GW, 라우팅 테이블을
직접 정의한다. 단, 인터페이스(input/output)는 공식 모듈과 호환 가능한 네이밍을 따른다 →
나중에 공식 모듈로 교체해도 호출자 코드 변경이 최소화된다.

### 2) NAT Gateway는 단일(single)로 운영한다

`single_nat_gateway = true`. NAT GW 1개를 첫 번째 AZ에 두고, 모든 Private Subnet이
이 NAT을 공유하도록 라우팅한다.

### 3) 서브넷 토폴로지

VPC: `10.0.0.0/16` (서울 리전, 2-AZ: `ap-northeast-2a`, `ap-northeast-2c`)

| 서브넷 종류 | CIDR (AZ-a / AZ-c) | 용도 |
|---|---|---|
| Public | `10.0.0.0/24`, `10.0.1.0/24` | ALB, NAT Gateway |
| Private | `10.0.16.0/20`, `10.0.32.0/20` | EKS 워커 노드, Pod IP |
| Intra | `10.0.48.0/24`, `10.0.49.0/24` | RDS 등 격리 자산 (인터넷 outbound 없음) |

Private Subnet을 `/20`(약 4,000 IP)로 잡는 이유는 AWS VPC CNI가 Pod마다 VPC IP를
직접 할당해 IP 소진이 빠르기 때문이다 (AWS EKS Best Practices 명시 권장).

## Consequences

### 직접 작성에 대한 영향
+ VPC 리소스 단위(IGW, NAT, RT, RTA)를 모두 직접 다뤄봄 → 면접에서 네트워크 이해도 어필
+ 코드 양이 적당해 (~200 lines) 디버깅·리뷰·확장 직관적
+ 모듈 인터페이스를 우리가 통제 → 향후 EKS/ALB/RDS 모듈과의 결합 형태를 자유롭게 설계 가능
- 공식 모듈이 제공하는 고급 기능(VPC Flow Logs 자동 구성, 다양한 NACL 옵션, IPAM 통합 등)
  을 쓰려면 직접 추가해야 함
- 보안·기능 업데이트가 자동으로 따라오지 않음 → 주기적인 수동 점검 필요

### 단일 NAT Gateway에 대한 영향
+ 비용 절감: 시간당 약 $0.045 (다중 AZ 대비 절반). 데이터 처리비는 동일.
+ 매일 destroy 패턴과 시너지 — 어차피 매일 만들고 부수므로 HA의 의미 제한적
- AZ-a 장애 시 Private Subnet의 모든 outbound 인터넷 통신 두절 → Pod의 외부 API 호출
  불가
- 운영 환경에선 권장하지 않는 토폴로지

### 격리 Subnet 추가에 대한 영향
+ RDS 등 추후 도입 시 별도 네트워크 설계 작업 없이 즉시 활용 가능
+ EKS 워커 노드와 격리되어 있어 보안 강화
- 미사용 자원이지만 무료 (서브넷 자체는 과금되지 않음)

## Future Migration Path

### 운영 환경 전환 시 변경할 것
- `single_nat_gateway = false` (Multi-AZ NAT)
- AZ를 3개로 확장 (`ap-northeast-2a/b/c`)
- VPC Flow Logs를 CloudWatch Logs 또는 S3로 활성화
- NACL을 default 외에 dedicated NACL로 분리하여 더 세밀한 통제

### 공식 모듈로 마이그레이션 시
인터페이스가 호환되도록 작성했으므로 envs/dev/main.tf에서 source만 교체:
```hcl
module "vpc" {
- source = "../../modules/vpc"
+ source  = "terraform-aws-modules/vpc/aws"
+ version = "~> 6.0"
  # 나머지 변수는 거의 그대로 사용 가능
}
```
일부 변수명만 매핑 조정 필요 (`public_subnet_ids` → `public_subnets` 등).

## Alternatives Considered

### 공식 모듈 (terraform-aws-modules/vpc/aws v6.x)
- 200+ resource를 한 줄로 호출 가능
- 운영 환경 표준이며 AWS Best Practices 자동 반영
- 그러나 본 프로젝트의 학습·면접 가치가 줄어 hybrid 전략으로 보완

### Multi-AZ NAT Gateway
- AZ 단위 장애에 강함 (운영 환경 표준)
- 시간당 비용 2배 → 매일 destroy 패턴에선 매일 두 번 비용 발생
- 포트폴리오에선 비용 효율 우선

### IPv6 클러스터
- IP 소진 문제를 근본적으로 회피
- AWS EKS Best Practices가 적극 권장하는 방향
- 그러나 도입 복잡도가 높고 면접 시 IPv4 운영 경험을 어필하기 어려움
- 현재는 IPv4로 진행, ADR로 인지함을 명시

## References
- AWS EKS Best Practices Guide — Networking:
  https://docs.aws.amazon.com/eks/latest/best-practices/networking.html
- terraform-aws-modules/vpc/aws v6.6.1: 공식 모듈 인터페이스를 본 모듈 설계 시 참고
- ADR-0011: Terraform State 백엔드 (이 ADR의 backend 설정이 의존)