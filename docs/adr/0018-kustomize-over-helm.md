# ADR-0018: K8s Manifest 도구 — Kustomize 채택 (vs Helm)

## Status
Accepted (2026-04-29)

## Context

Phase 3에서 portfolio-manifests 레포에 K8s manifest를 작성한다. 도구 선택지:

1. **Plain YAML**: 환경별 manifest를 복붙으로 관리 → DRY 위배, 휴먼 에러 다수
2. **Kustomize**: kubectl 빌트인, base + overlays 패턴, plain YAML 유지
3. **Helm**: 패키지 관리자, Go 템플릿, 차트 배포 표준

CNCF 2025 Survey 기준 Helm 75% 채택, Kustomize는 kubectl에 빌트인되어 별도 채택률 추적 안 됨.
ArgoCD/Flux 둘 다 두 도구 모두 native 지원.

## Decision

**자체 마이크로서비스 manifest는 Kustomize로 관리한다**.
3rd party 컴포넌트(Prometheus, Grafana, ArgoCD 등 — Phase 4+)는 **Helm 차트 사용 가능**.

### 구체 구조
```
apps/<service>/
  base/                  # 공통 (Deployment, Service, ...)
  overlays/<env>/        # 환경별 patch (replicas, resources, configmap)
```

## Consequences

### 긍정
+ Plain YAML 유지 → 학습 곡선 거의 없음, 코드 리뷰 용이
+ kubectl 빌트인 (`kubectl apply -k`) — 별도 도구 설치 불필요
+ ArgoCD가 `kustomize build` 결과를 그대로 적용 → 렌더링 결과와 실제 적용본이 동일 (예측 가능성)
+ 환경 간 차이가 명시적 (overlay만 보면 dev vs prod 차이 한눈에)

### 부정
- 조건문/반복문 부재 → 환경이 매우 다르면 patch 파일이 많아짐
- 패키지 관리 없음 → 외부 배포(다른 팀이 우리 서비스 설치)에 부적합
  - 본 프로젝트는 self-contained라 무관

### 운영 환경 진화 경로
- 환경이 5개 이상 늘면 components 패턴(공통 옵션 모듈화) 도입 검토
- 외부 팀이 우리 서비스를 패키지 형태로 받아야 하면 그때 Helm 도입 (혼용 가능)

## Alternatives Considered

### Helm
- 패키지 관리, 템플릿 변수, 릴리즈 관리 등 풍부한 기능
- 그러나 Go 템플릿 학습 곡선 + 렌더링 후에야 실제 YAML 확인 가능 → GitOps 투명성 저해
- 자체 앱엔 과도, 3rd party 차트엔 적합 → 분리 전략 채택

### Plain YAML 복붙
- 가장 단순
- DRY 위배, 환경 추가 시 휴먼 에러 다수
- 거절

## References
- CNCF 2025 Survey: Helm 75% 채택률
- ArgoCD Kustomize 공식 가이드
- Kustomize v5 (kubectl 1.21+ 빌트인)