# ADR-0021: GitOps 도입 — ArgoCD + Auto sync + Self-heal

## Status
Accepted (2026-04-30)

## Context

Phase 3 Epic 6에서 CD 파이프라인 도입. Epic 5(CI)까지의 흐름:
```
git push → GitHub Actions → ECR push → 끝
                                       ↑ K8s 배포는 수동 (kubectl apply -k)
```

진짜 운영 패턴은:
```
git push → CI → ECR push → manifest 갱신 → ArgoCD 자동 감지 → 자동 배포
```

Epic 6은 마지막 두 단계 (manifest 갱신 + ArgoCD)를 도입.

결정 항목:
- CD 도구 선택 (ArgoCD vs FluxCD vs Jenkins)
- 설치 방식 (Helm vs raw manifests)
- 외부 노출 방식
- watch 대상 (서비스마다 vs 전체 1개)
- Sync 정책 (Manual vs Auto vs Auto+Self-heal)
- ignoreDifferences 정책 (HPA 충돌 방지)

## Decision

### 1) CD 도구: ArgoCD v3.3.6
- **GitOps 표준** (CNCF Graduated 프로젝트)
- 사용자 친화적 UI (면접 시연 가치)
- Helm + Kustomize 둘 다 native 지원
- Self-heal로 진짜 GitOps 패턴 강제

### 2) 설치 방식: Helm chart v9.5.0
- ADR-0018의 "3rd party는 Helm" 원칙 두 번째 적용 (첫 번째는 ALB Controller, ADR-0019)
- raw manifest 대비 upgrade 흐름 깔끔
- values.yaml로 선언적 설정

### 3) 외부 노출: 별도 ALB Ingress
선택지 검토:
- A. 앱용 ALB(`portfolio`)와 path 공유: path prefix 설정 복잡
- B. 별도 ALB(`argocd` group): 설정 단순, 비용 +$0.025/h
- C. host-based: 도메인 필요 (없음)

**B 채택**. 이유:
- 시연 단계 단순성 우선
- Phase 3 마무리라 destroy 시 같이 정리
- 운영 책임 영역 분리 (앱 Ingress vs 운영 Ingress)

### 4) `--insecure` 플래그 (gotcha 방지)
ArgoCD는 default로 HTTPS만 받음. ALB가 TLS termination + HTTP backend 패턴에서:
- ArgoCD는 HTTP 요청을 HTTPS로 redirect 시도
- ALB는 HTTP라 또 redirect → infinite loop

해결: `server.extraArgs: [--insecure]` 박아 HTTP backend 동작 강제.

이 사고는 검색 결과에서도 "the --insecure gotcha most tutorials miss"로 박제된 흔한 함정.

### 5) Watch 대상: 단일 Application (apps/all/overlays/dev)
선택지:
- A. 전체 1개 Application
- B. 서비스마다 별도 Application 3개
- C. App-of-Apps 패턴

**A 채택**. 이유:
- 1인 dev 환경엔 충분
- 시연 시 "한 번에 3개 서비스 배포" 명확
- App-of-Apps는 진짜 운영 표준이지만 학습 곡선 있음 (Phase 5+ 검토)

### 6) Sync 정책: Auto + Self-heal + Prune
**진짜 GitOps 패턴**:
```yaml
syncPolicy:
  automated:
    prune: true       # Git에서 삭제된 자원 cluster에서도 제거
    selfHeal: true    # 수동 변경 자동 복구
```

장점:
- "Git이 진실의 소스" 원칙 강제
- kubectl로 직접 변경하면 ArgoCD가 자동 복구
- PR 머지 즉시 자동 배포 (운영 흐름 자동화)

부정적 측면:
- 실수로 잘못된 manifest 머지 시 즉시 적용
- 수동 디버깅 시 ArgoCD 비활성화 또는 sync 일시 중지 필요

**판단**: 1인 dev 환경에선 진짜 GitOps 패턴이 면접 어필 강함. 운영 환경에선 staging/prod 분리해 staging은 auto, prod는 manual 권장.

### 7) ignoreDifferences: HPA 충돌 방지
deployment.replicas는 HPA가 갱신하는 값. selfHeal=true면 ArgoCD가 Git 상태(replicas: 1)로 복구 시도 → HPA가 다시 늘림 → 무한 충돌.

해결:
```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
      - /spec/replicas
```

이 설정 없으면 sync는 성공해도 cluster가 매 분 출렁임.

### 8) 옵션 비활성화 (불필요한 자원 절감)
- `dex`: 외부 OIDC 미사용 (admin local 인증만)
- `applicationSet`: 멀티 환경 미사용
- `notifications`: Phase 5+ Slack 알림 도입 시 활성화
- HA mode: 단일 controller/repoServer (1인 dev 환경)

## Consequences

### 긍정
+ ADR-0018 (Kustomize/Helm 혼용) 두 번째 실전 적용
+ 진짜 GitOps 패턴 — `git push` → 자동 배포
+ Self-heal로 cluster drift 자동 복구
+ 면접 시연 가치 매우 강함 (UI + 자동 동기화 시연)
+ Epic 5(CI) → Epic 6(CD) 전체 파이프라인 완성

### 부정
- ArgoCD 자체 자원 사용 (Pod 5개, ~500Mi 메모리)
- ALB 추가 (~$0.025/h)
- Self-heal로 운영 디버깅 시 sync 일시 중지 필요
- Phase 5+에서 portfolio-manifests private 레포 전환 시 credential 등록 필요

### 한마디로 정리
"Phase 3 Epic 6에서 ArgoCD를 Helm으로 설치하고 GitOps 패턴을 도입했습니다.

핵심 결정 4가지:
1. **별도 ALB**: 앱용과 ArgoCD용 ALB를 분리해 운영 책임 영역 명확화
2. **--insecure 플래그**: ALB TLS termination 시점의 흔한 함정(redirect loop)을 미리 방지
3. **Auto sync + Self-heal + Prune**: 진짜 GitOps 패턴 — kubectl 직접 변경도 자동 복구
4. **ignoreDifferences로 deployment.replicas 제외**: HPA의 자동 스케일링과 ArgoCD self-heal이 무한 충돌하는 것 방지

특히 4번이 흔한 사고 사례입니다. HPA가 늘린 replicas를 ArgoCD가 Git 상태로 복구 → HPA가 다시 늘림 → 무한 출렁임. 이걸 미리 인지하고 jsonPointers로 무시 처리한 게 운영 경험을 보여주는 박제 자료입니다."

## 운영 시 고려사항

### Sync 정책의 운영 환경 차별화 (Phase 5+)
```yaml
# dev: Auto + Self-heal (현재)
# staging: Auto sync (selfHeal=false, 수동 디버깅 허용)
# prod: Manual sync (PR + 수동 sync 버튼 필수)
```

### Webhook 설정 (Phase 5+)
ArgoCD default polling은 3분 주기. webhook 설정 시 즉시 감지:
- GitHub webhook → ArgoCD `/api/webhook`
- portfolio-manifests의 push 즉시 sync 트리거

### App-of-Apps 패턴 (Phase 5+)
부모 Application이 자식들을 관리:
```
root-app
├── portfolio-app (현재)
├── monitoring-stack
├── logging-stack
└── ingress-controllers
```

Phase 4 Observability 도입 시 자연스러운 진화 경로.

## ALB destroy 순서 (함정)

Application/Ingress를 먼저 삭제해야 ALB 정리됨:
```bash
kubectl delete -f application.yaml      # Application 먼저
sleep 30
kubectl delete -f ingress.yaml          # ALB 정리 트리거
sleep 60                                # ENI deregister 대기
helm uninstall argocd -n argocd
# 그 다음 앱용 ingress + 앱 + ALB Controller + Terraform destroy
```

## Alternatives Considered

### FluxCD
- ArgoCD와 함께 GitOps 양대 산맥
- UI가 ArgoCD보다 약함 (CLI 위주)
- 면접 시연 가치 낮음
- 거절

### Jenkins X / Spinnaker
- 더 무거운 도구
- 1인 포트폴리오엔 과한 도입
- 거절

### CI에서 직접 kubectl apply (CD 없음)
- GitHub Actions에서 EKS API 직접 호출
- 단순하지만 진짜 GitOps 아님 (drift 감지 없음)
- 거절

### Manual sync (auto 아님)
- 안전하지만 수동 단계 추가
- dev 환경엔 과한 보수성
- 거절 (Phase 5+ prod에선 채택 검토)

## References
- ArgoCD 공식: https://argo-cd.readthedocs.io/
- Helm chart: https://github.com/argoproj/argo-helm
- ADR-0018: Kustomize/Helm 혼용 원칙 (본 ADR이 두 번째 Helm 적용)
- ADR-0019: ALB Controller (본 ADR이 ALB Ingress 두 번째 적용)
- ADR-0020: CI 파이프라인 (본 ADR이 CD 부분 완성)
- 함정 #X (PROJECT_CONTEXT.md): ArgoCD --insecure gotcha (예정)
- 함정 #X (PROJECT_CONTEXT.md): HPA + ArgoCD selfHeal 충돌 (예정)