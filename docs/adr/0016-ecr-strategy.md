# ADR-0016: ECR 리포지토리 전략 (서비스별 + IMMUTABLE + scan_on_push + lifecycle)

## Status
Accepted (2026-04-28)

## Context

3개 마이크로서비스(product-service, order-service, payment-service)의 Docker 이미지를
저장할 컨테이너 레지스트리가 필요하다. 결정 항목:
1. 레지스트리 선택 (ECR vs Docker Hub vs GitHub Container Registry)
2. 리포지토리 단위 (서비스별 분리 vs 모노레포)
3. 태그 변경 정책 (mutable vs immutable)
4. 보안 스캔 정책
5. 이미지 누적 관리 (lifecycle)

## Decision

### 1) 레지스트리: ECR
- EKS 노드 IAM Role(`AmazonEC2ContainerRegistryReadOnly`)로 자동 인증, Pod이 별도 imagePullSecret 불필요
- AWS 영역 안 통신 → 빠른 pull 속도 + 외부 송신 비용 0
- VPC endpoint 활용 가능 (Phase 4+에서 추가 검토)

### 2) 리포 단위: 서비스별 분리
- `portfolio/product-service`, `portfolio/order-service`, `portfolio/payment-service`
- 각 리포가 lifecycle/스캔 결과/권한을 독립 관리

### 3) Image tag mutability: IMMUTABLE
- 한 번 push된 태그는 덮어쓰기 불가
- 배포 추적 가능성 확보 (특정 태그 = 특정 빌드)
- "운영 환경에서 latest를 쓰지 않는다" 원칙과 정합

### 4) 보안 스캔: scan_on_push = true (+ Trivy 빌드 시점 스캔과 다층 방어)
- ECR Native scan: OS 패키지 + 라이브러리 취약점 자동 검출
- Trivy(ADR-0010): 빌드 시점 IDE/CI에서 검출 → 일찍 차단
- 두 가지 모두 켜면 다층 방어 (defense in depth)

### 5) Lifecycle 정책
- **untagged 이미지**: 1일 후 자동 삭제 (PR 빌드, 실패한 빌드 누적 방지)
- **tagged 이미지**: 최신 10개만 유지 (긴급 롤백 여유 확보 + 비용 통제)

## Consequences

### 긍정
+ EKS pull 인증이 노드 Role로 자동화되어 K8s manifest 단순
+ IMMUTABLE 정책으로 "어제 정상이었는데 같은 태그가 갑자기 다른 코드로 바뀜" 사고 차단
+ 스캔 결과가 ECR 콘솔에 자동 누적 → CVE 트렌드 추적 용이
+ Lifecycle 자동화로 "리포 GB가 무한 증가하여 비용 폭주" 방지

### 부정
- IMMUTABLE: 잘못된 빌드 push 시 태그 재사용 불가 → 새 태그(`0.1.1`, `0.1.2`)로 재push 필요
  - SemVer + Git SHA 태깅 패턴으로 오히려 추적성 향상의 부수 효과
- Lifecycle 10개 제한: 장기간 운영 후 옛 버전이 필요할 때 부재 가능
  - Phase 6+ 운영 단계에서 30~50개로 상향 검토

### 비용 영향
- ECR 저장: 첫 50GB까지 $0.10/GB/월 (3개 서비스 × 10개 이미지 × ~200MB ≈ 6GB → 월 $0.60)
- 데이터 전송: 같은 리전 내 EKS pull은 무료
- 스캔: ECR Native scan은 무료
- **예상 ECR 월 비용 < $1**

## Alternatives Considered

### Docker Hub
- 무료 tier 제한 (pull rate limit 100/6h)
- EKS 노드들이 같은 IP로 묶여 rate limit에 빨리 도달
- 거절

### GitHub Container Registry (ghcr.io)
- GitHub Actions와 통합 좋음
- 그러나 EKS 노드 인증을 위해 imagePullSecret 관리 필요 → 운영 부담
- 비용/속도/통합 모두 ECR이 우위
- 거절

### MUTABLE 태그 (latest 패턴)
- 개발 편의성 우위
- 배포 추적성 손실 — "이 Pod이 정확히 어떤 코드인지 모름"
- ADR-0010 Trivy 빌드 정책과도 충돌 (같은 태그 재push 시 스캔 결과 덮어씀)
- 거절

## References
- AWS ECR Pricing: https://aws.amazon.com/ecr/pricing/
- ADR-0010: Trivy 컨테이너 스캔 정책 (본 ADR과 다층 방어 구성)
- ADR-0017: GitHub Actions OIDC (이 ECR에 push할 권한 부여)