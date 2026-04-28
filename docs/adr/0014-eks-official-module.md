# ADR-0014: EKS 공식 모듈 채택 (vs 직접 작성)

## Status
Accepted (2026-04-28)

## Context

VPC 모듈은 ADR-0012에서 "직접 작성 + 인터페이스만 공식 모듈 호환" 하이브리드 전략을
채택했다. EKS도 같은 전략을 적용할지, 아니면 공식 모듈을 그대로 호출할지 결정이 필요했다.

## Decision

EKS는 **`terraform-aws-modules/eks/aws ~> 21.0`** 공식 모듈을 그대로 호출한다.
다만 우리 프로젝트 컨벤션(default 값, 환경별 override 패턴)을 위해 `modules/eks/`에서
공식 모듈을 한 번 wrapping한다.

### VPC와 다른 결정인 이유

| 항목 | VPC | EKS |
|---|---|---|
| 직접 작성 시 코드 양 | ~200 lines | 1500+ lines |
| 핵심 리소스 종류 | 8종 (VPC, Subnet, IGW, NAT, EIP, RT, RTA, NACL) | 30+ 종 (Cluster, Node Group, IAM Roles × 다수, SG, Add-ons, Access Entries, Pod Identity, OIDC Provider, Launch Template…) |
| 학습 가치 vs 시간 | 가성비 좋음 (네트워크 이해 깊어짐) | 너무 무거움 (1주일은 잡아먹음) |
| 베스트 프랙티스 변동 빈도 | 낮음 | 매우 높음 (K8s 버전마다, EKS 신규 기능마다) |
| 면접 어필 포인트 | "직접 짜본 경험" | "공식 모듈을 어떤 옵션으로 어떻게 구성했는지 설명 가능" 충분 |

EKS는 직접 작성 시 코드를 다 이해하지 못한 채 베끼게 될 위험이 크다. 공식 모듈을
사용하되 모든 옵션의 의미를 설명할 수 있는 수준의 이해가 더 실무적이다.

## Consequences

### 긍정
+ 1500+ 라인의 IAM/SG/Add-on/Node Group/Access Entry 코드 작성 우회
+ EKS 신규 기능(EKS Pod Identity, Cluster Access Entry 등) 자동 반영
+ 공식 모듈의 issue tracker가 베스트 프랙티스 학습 자료가 됨
+ AWS Provider 메이저 업그레이드 시 공식 모듈이 호환성 검증을 대신 해줌

### 부정
- 모듈 내부 구현은 블랙박스 — 디버깅 시 .terraform/modules/eks 하위 추적 필요
- 모듈이 추구하는 디폴트와 우리 요구가 다르면 옵션을 깊이 파야 함
- 모듈 메이저 업그레이드(v21 → v22)는 breaking change 가능 — 정기 검증 필요

### Wrapping 패턴의 장점
공식 모듈을 envs/dev/main.tf에서 직접 호출해도 동작은 동일하지만, modules/eks/에서
한 번 감싸면:
- staging/prod 환경 추가 시 default 값을 자동 상속
- "AL2023 사용", "Pod Identity 활성화" 같은 우리 정책을 한 곳에서 강제
- 공식 모듈 메이저 업그레이드 시 envs/* 전체 수정 없이 modules/eks만 업그레이드

## Alternatives Considered

### 직접 작성 (VPC 패턴 그대로)
- 일관성 측면에서 매력적이나 학습 vs 시간 trade-off가 EKS에선 너무 나쁨
- 향후 K8s 버전 업그레이드, EKS 신규 기능 도입 때마다 수동 업데이트 부담
- 거절

### 공식 모듈 직접 호출 (wrapping 없음)
- envs/dev/main.tf에서 module "eks" { source = "terraform-aws-modules/eks/aws" }로 직접
- 가장 단순. 단, 환경 추가 시 default 중복 발생
- 1인 프로젝트에선 무방하나 staging/prod 확장성을 위해 wrapping 채택

## Future Migration Path

### EKS 모듈 v22 출시 시
1. modules/eks/main.tf의 version = "~> 21.0"을 v22로 변경
2. release notes의 breaking changes를 반영해 옵션 조정
3. envs/dev에서 plan으로 변경 사항 검증
4. envs/* 코드는 그대로

### EKS Auto Mode 전환 시
별도 ADR 작성. compute_config 블록 추가로 전환 가능하나 Managed Node Group 명시적
관리의 학습 가치를 우선 유지.

## References
- terraform-aws-modules/eks/aws Registry:
  https://registry.terraform.io/modules/terraform-aws-modules/eks/aws
- 본 ADR이 wrapping하는 공식 모듈 v21.x changelog:
  https://github.com/terraform-aws-modules/terraform-aws-eks/blob/master/CHANGELOG.md
- ADR-0012: VPC 직접 작성 결정 (대조군)