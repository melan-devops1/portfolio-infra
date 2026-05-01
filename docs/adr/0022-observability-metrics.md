# ADR-0022: Observability Metrics — kube-prometheus-stack + ALB readinessGate + 운영 사고 박제

## Status
Accepted (2026-05-02)

## Context

Phase 4 Epic 7에서 메트릭 수집 + 시각화 + 알림 인프라 도입. ADR-0010 (Trivy/Security)에 이은
운영 표준 두 번째 — Observability 첫 단계.

기존 흐름의 한계:
- Spring Boot Actuator 메트릭은 노출되지만 수집/시각화 없음
- Pod/Container 메트릭(CPU, 메모리)은 metrics-server에만 (HPA용, 시각화 없음)
- 알림 자동화 0
- 부하 시연 시 RED 메트릭(Rate, Errors, Duration) 추적 불가

Epic 7-A에서 다음 결정 + 시연:
- 메트릭 인프라 선택
- 외부 노출 방식
- 메트릭 수집 자동화
- 시연 + 사고 진단 (운영 자료 박제)

## Decision

### 1) 메트릭 stack: kube-prometheus-stack v84.3.0
- Helm chart 한 번 설치로 6개 컴포넌트:
  - Prometheus (TSDB), Operator, Alertmanager, Grafana, kube-state-metrics, node-exporter
- ADR-0018 "3rd party는 Helm" 세 번째 적용:
  - 첫 번째: ALB Controller (ADR-0019)
  - 두 번째: ArgoCD (ADR-0021)
  - 세 번째: kube-prometheus-stack (본 ADR) ⭐
- 검증: EKS 1.33 + chart v84.3.0 (2026-04 공식 검증)

### 2) GitOps 관리: ArgoCD Application + multi-source
- Helm chart는 prometheus-community 공식 repo
- values.yaml은 portfolio-manifests의 monitoring/kube-prometheus-stack/values.yaml
- ApplicationCRD의 sources 필드로 결합
- ADR-0021의 Auto sync + Self-heal + Prune 패턴 일관성

### 3) EKS managed control plane scraper 비활성화
EKS는 etcd, kube-controller-manager, kube-scheduler를 AWS 자체 인프라에서 운영하고 metrics 노출 안 함.
활성화 시 false alert + noisy 로그.

```yaml
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeEtcd:
  enabled: false
```

이건 EKS 환경의 핵심 함정 — 무시하면 첫 사고.

### 4) ServiceMonitor selector 비활성화 (모든 namespace 자동 감지)
```yaml
serviceMonitorSelectorNilUsesHelmValues: false
serviceMonitorSelector: {}
serviceMonitorNamespaceSelector: {}
```

monitoring namespace의 Prometheus가 default namespace의 portfolio 서비스 ServiceMonitor 자동 감지.
운영 표준 — 멀티 namespace 환경에 자연스러움.

### 5) Grafana 외부 노출: 별도 ALB
- ADR-0021 (ArgoCD ALB) + 본 ADR (Grafana ALB) 패턴 일관성
- group.name=grafana로 별도 ALB 인스턴스
- 운영 책임 영역 명확 분리 (앱 vs 운영 도구)

### 6) Spring Boot 메트릭 노출 (앱 측 박제)
portfolio-app의 application.yaml에 Phase 1~2 단계에서 미리 박제됨:
```yaml
management:
  endpoints:
    web:
      exposure:
        include: health, info, prometheus, metrics, ...
  endpoint:
    prometheus:
      access: read-only
  metrics:
    tags:
      application: ${spring.application.name}
  prometheus:
    metrics:
      export:
        enabled: true
```

선견지명 박제로 Epic 7 진입 시 앱 변경 0. PROJECT_CONTEXT.md의 가치 입증.

### 7) ServiceMonitor 패턴
3개 서비스마다 별도 ServiceMonitor:
```yaml
spec:
  selector:
    matchLabels:
      app: <service-name>
  namespaceSelector:
    matchNames:
      - default
  endpoints:
    - port: http
      path: /actuator/prometheus
      interval: 15s
```

`port: http`는 named port 사용 (8081/8082/8083 직접 박지 않음). Service의 named port와 정합.

### 8) ALB readinessGate 도입 (HPA scale-up 부팅 race 해결)

부하 시연 중 발견한 진짜 운영 사고를 박제:
- 60초 부하 + Chaos 5% → 502 78% 발생
- 진단: HPA scale-up 시 새 Pod 부팅(~30초) 동안 ALB target group에 등록
- 부팅 안 끝난 Pod에 트래픽 전달 → connection refused → 502 cascade

해결: AWS Load Balancer Controller의 readinessGate mutating webhook 활용
```bash
kubectl label namespace default elbv2.k8s.aws/pod-readiness-gate-inject=enabled
```

namespace에 label 한 번 박으면 controller가 모든 새 Pod에 readinessGate 자동 주입.
ALB target health 검증 통과 전엔 Pod이 Ready 상태 안 됨 → 트래픽 차단.

조건:
- Service의 target-type: ip 필수 (instance면 작동 안 함)
- portfolio-ingress 이미 박제됨 ✅

매 destroy/apply 사이클마다 namespace label 재적용 필요 (default ns) — 박제 항목.

### 9) 부하 시연 + 진단 (운영 사고 박제)

readinessGate 적용 후 다시 부하 → **502 100%** 만남 (예상은 5%).

Pod 로그 직접 진단:
```
ProductUnavailableException: Product not available: id=1, status=404 NOT_FOUND
  at com.portfolio.order.service.ProductClient.lambda$getProduct$0
```

**진짜 원인 — H2 in-memory DB 휘발 (함정 #28의 운영 사례)**:
1. readinessGate 적용 위해 rollout restart
2. product-service Pod 재생성 → H2 데이터 휘발
3. order의 ProductClient가 GET /api/products/1 → 404
4. ProductUnavailableException → 502 cascade

이게 본 ADR의 가장 중요한 운영 박제 — **502는 항상 인프라 문제 아님**.

### 10) 시연 자료 + 알림 규칙 (Epic 7-B로 분리)
시연 자료 충분 박제 후 Epic 7-B는 다음 세션:
- PrometheusRule (5xx burst, HPA scale-up 알림 등)
- AlertmanagerConfig 라우팅
- 커스텀 Grafana 대시보드 (RED 메트릭)
- (선택) Slack 통합

## Consequences

### 긍정
+ Prometheus + Grafana 풀 작동 — 메트릭 수집 + 시각화
+ ServiceMonitor로 자동 메트릭 수집 (Pod 단위)
+ ADR-0018 "Helm" 세 번째 일관성 적용
+ ADR-0021 "ArgoCD multi-source" 패턴 적용
+ ALB readinessGate로 부팅 race 해결 (운영 표준)
+ EKS 특화 함정 박제 (control plane scraper 비활성화)

### 부정
- Prometheus stack 자원 (~3GiB RAM, 17GiB PVC)
- Grafana 별도 ALB (~$0.025/h)
- 매 destroy/apply 사이클마다 namespace label 재적용 (자동화 빚)
- Phase 4 RDS 도입 전엔 부하 시연 한계 (H2 휘발)

### 운영 빚 (Phase 4 마무리 항목)
- [ ] **RDS PostgreSQL 도입** (함정 #28 + 본 ADR 시연 사고 해결):
      H2 in-memory의 본질적 한계 해결.
      여러 Pod 간 데이터 일관성 보장 + rollout restart에도 데이터 영속.
- [ ] **portfolio-manifests에 namespace label 박제 검토**:
      현재 kubectl 직접. apps/all/overlays/dev에 namespace.yaml 추가 검토.
- [ ] **ECR migration to bootstrap** (Phase 6 운영 환경 진입 시):
      매 destroy 사이클마다 ECR 이미지 재 push 필요.
      PROJECT_CONTEXT.md에 보류 결정 박제됨.

### 면접 답변용 포인트

#### Q. Observability 어떻게 구축했나요?

> "Phase 4 Epic 7에서 kube-prometheus-stack을 ArgoCD Application으로 등록해 GitOps로 관리했습니다.
>
> 핵심 결정 4가지:
> 1. **EKS managed control plane scraper 비활성화**: AWS가 etcd/scheduler/controller-manager를 자체 인프라에서 운영해 metrics 노출 안 함. 활성화하면 false alert + noisy 로그 (EKS 환경 핵심 함정).
> 2. **ArgoCD multi-source pattern**: Helm chart는 공식 repo, values.yaml은 우리 git repo. ApplicationCRD의 sources 필드로 결합.
> 3. **ServiceMonitor selector {}**: 모든 namespace 자동 감지. monitoring namespace의 Prometheus가 default namespace의 ServiceMonitor 수집.
> 4. **별도 ALB Ingress** (group.name=grafana): ArgoCD ALB와 분리, ADR-0021 패턴 일관성."

#### Q. 시연 중 사고 만난 적 있나요?

> "Phase 4 Epic 7 부하 시연에서 두 가지 실제 운영 사고 만났습니다.
>
> **사고 1: HPA scale-up 부팅 race**
> 60초 부하 + Chaos 5% → 502 78%. 진단해보니 Chaos 5%로 설명 안 되는 비율이라 Pod 이벤트 확인 → 'Startup probe failed: connection refused'. HPA가 새 Pod 만들었는데 Spring Boot 부팅(~30초) 동안 ALB target group에 이미 등록 → 부팅 안 끝난 Pod에 트래픽 → 502 cascade.
> 
> 해결: AWS Load Balancer Controller의 readinessGate 활용. namespace에 `elbv2.k8s.aws/pod-readiness-gate-inject=enabled` label 박으면 controller가 mutating webhook으로 모든 새 Pod에 readinessGate 자동 주입. ALB target health 통과 전엔 Pod이 Ready 안 되어 트래픽 차단.
>
> **사고 2: H2 in-memory DB 휘발 cascade**
> readinessGate 적용 위해 rollout restart 후 다시 부하 → 502 100%. 진단해보니 진짜는 404 cascading. Pod 로그 보니 'ProductUnavailableException: Product not available: id=1, status=404 NOT_FOUND'. rollout restart로 product-service의 H2 데이터 휘발 → order의 ProductClient가 GET 시 404 → 502 변환.
>
> 이게 시작 단계에 박제했던 'H2 in-memory의 운영 한계'(함정 #28)의 실제 발현. Phase 4 RDS 도입이 명확히 빚이라는 입증. '502는 항상 인프라 사고만 아님'을 직접 학습."

## Alternatives Considered

### Datadog / New Relic (SaaS)
- 운영 부담 적음
- 그러나 비용 + 면접 자료 가치 작음 (Open Source 표준 운영 경험이 더 강함)
- 거절

### CloudWatch Container Insights
- AWS 네이티브
- 그러나 Grafana 같은 시각화 부족
- 거절 (Phase 5+에 보조 도구로 검토 가능)

### Prometheus 직접 설치 (kube-prometheus-stack 없이)
- 더 가벼움
- 그러나 Operator + 기본 대시보드 + Alertmanager 통합 부족
- 거절

### Grafana 대신 다른 시각화
- 운영 표준은 Grafana
- 거절

## References
- ADR-0010: Trivy 스캔 baseline (보안 측 운영 첫 단계)
- ADR-0017: GitHub Actions OIDC
- ADR-0018: Kustomize/Helm 혼용 (본 ADR 세 번째 Helm 적용)
- ADR-0019: ALB Controller (본 ADR이 ALB readinessGate로 두 번째 활용)
- ADR-0021: ArgoCD GitOps (multi-source pattern 활용)
- 함정 #28 (PROJECT_CONTEXT.md): H2 in-memory 운영 한계 (본 ADR 시연 사고로 실제 발현)
- 함정 #48 (PROJECT_CONTEXT.md): HPA scale-up 부팅 race
- 함정 #49 (PROJECT_CONTEXT.md): ALB readinessGate 적용 패턴
- 함정 #50 (PROJECT_CONTEXT.md): 502의 진짜 원인은 404 cascade
- kube-prometheus-stack: https://github.com/prometheus-community/helm-charts
- AWS LBC readinessGate: https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/pod_readiness_gate/