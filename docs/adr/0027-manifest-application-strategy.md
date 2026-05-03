# ADR-0027: K8s Manifest 적용 영역 분리 (ArgoCD App vs Raw kubectl)

- **Status**: Accepted
- **Date**: 2026-05-02
- **Deciders**: 1인 프로젝트 (DevOps 포트폴리오)
- **Phase**: Phase 4 Epic 7~9 (전반적 운영 정책)

## Context

ArgoCD GitOps(ADR-0021)로 portfolio-app을 자동 sync 중. 그러나 monitoring/logging/tracing stack을 추가하면서 적용 영역이 일관되지 않은 상태였다.

### 현재 portfolio-manifests 구조

```
portfolio-manifests/
├ apps/all/overlays/dev/             ← portfolio-app ArgoCD watch 대상
├ argocd/                            ← ArgoCD 자체 관리
├ infrastructure/ingress/            ← 누가 적용?
├ monitoring/
│  ├ kube-prometheus-stack/         ← Helm chart (ArgoCD)
│  ├ prometheus-rules.yaml           ← raw K8s 자원
│  ├ alertmanager-config.yaml        ← raw K8s 자원
│  ├ service-monitors/               ← raw K8s 자원
│  └ grafana-ingress.yaml            ← raw K8s 자원
├ logging/
│  ├ fluent-bit/                    ← Helm chart (ArgoCD)
│  ├ namespace.yaml                  ← raw K8s 자원
│  ├ elasticsearch.yaml              ← raw K8s 자원
│  └ kibana*.yaml                    ← raw K8s 자원
└ tracing/
   ├ application.yaml                ← Helm chart (ArgoCD, Jaeger)
   ├ values.yaml
   └ jaeger-ingress.yaml             ← raw K8s 자원
```

### 발견된 문제

1. **infrastructure/ingress/는 어디서도 watch 안 됨** (함정 #56)
   - portfolio-app ArgoCD Application은 `apps/all/overlays/dev`만 watch
   - 매 사이클 수동 apply 필요. 잊으면 portfolio-ingress 안 생김 → 부하 시연 불가
2. **CRD 의존성 타이밍 문제** (함정 #46)
   - PrometheusRule, ServiceMonitor 등은 kube-prometheus-stack의 CRD 등록 후만 적용 가능
3. **일관 정책 부재**
   - 어느 자원을 ArgoCD App으로, 어느 자원을 raw kubectl로 적용할지 기준 없음

## Decision

### 적용 영역을 두 종류로 분리

#### A. ArgoCD Application으로 등록 (3종)

**기준**: Helm chart 의존, sync 시간 길고 자동 재시도 가치 있는 자원

| Application | 위치 | Source |
|---|---|---|
| `kube-prometheus-stack` | `monitoring/kube-prometheus-stack/application.yaml` | prometheus-community Helm 84.3.0 |
| `fluent-bit` | `logging/fluent-bit/application.yaml` | fluent Helm 0.57.3 |
| `jaeger` | `tracing/application.yaml` | jaegertracing Helm 4.7.0 |

이유:
- Helm chart는 다수 자원을 한 번에 박제 (CRD + Deployment + Service + ConfigMap + ServiceAccount + RBAC)
- sync 5~7분 소요, 중간 실패 시 ArgoCD 자동 재시도가 가치
- values.yaml 변경 시 ArgoCD가 변경 감지 + 재sync 자동

#### B. kubectl apply 직접 (raw K8s 자원)

**기준**: 단순 yaml, CRD 의존, 또는 ArgoCD watch 영역 밖

| 카테고리 | 자원 |
|---|---|
| Ingress | `infrastructure/ingress/`, `monitoring/grafana-ingress.yaml`, `logging/kibana-ingress.yaml`, `tracing/jaeger-ingress.yaml` |
| 모니터링 규칙 (CRD 의존) | `monitoring/prometheus-rules.yaml`, `monitoring/alertmanager-config.yaml`, `monitoring/service-monitors/*` |
| 단순 자원 | `logging/namespace.yaml`, `logging/elasticsearch.yaml`, `logging/kibana.yaml` |

이유:
- CRD 의존 자원: ArgoCD App sync 완료 전엔 적용 자체 불가 (`no matches for kind` 에러)
- 단순 yaml: ArgoCD 통한 watch 가치 적음. 매 사이클 한 번만 apply
- Helm chart에 대한 customization layer 역할

### 적용 순서 (매 destroy/apply 사이클)

```
1. terraform apply (EKS, RDS, ECR 등)
2. aws eks update-kubeconfig (함정 #25)
3. helm install aws-load-balancer-controller (terraform output 명령)
4. ArgoCD 설치 + portfolio-app Application 등록 (또는 자동)
5. ArgoCD Application 3개 등록 (kube-prometheus-stack, fluent-bit, jaeger)
   → CRD + namespace 자동 생성
6. kubectl label namespace default elbv2.k8s.aws/pod-readiness-gate-inject (함정 #49)
7. ConfigMap/Secret 3종 생성 (DB config, DB credentials, Slack webhook)
8. raw manifest apply:
   - kubectl apply -f infrastructure/ingress/
   - kubectl apply -f monitoring/prometheus-rules.yaml
   - kubectl apply -f monitoring/alertmanager-config.yaml
   - kubectl apply -f monitoring/service-monitors/
   - kubectl apply -f monitoring/grafana-ingress.yaml
   - kubectl apply -f logging/namespace.yaml
   - kubectl apply -f logging/elasticsearch.yaml
   - kubectl apply -f logging/kibana.yaml
   - kubectl apply -f logging/kibana-ingress.yaml
   - kubectl apply -f tracing/jaeger-ingress.yaml
```

### CRD 의존성 검증

ArgoCD App sync 완료를 다음 명령으로 확인 후 raw manifest 적용:

```bash
kubectl get crd | grep monitoring.coreos.com
# 다음 3개 보여야 함:
# - prometheusrules.monitoring.coreos.com
# - alertmanagerconfigs.monitoring.coreos.com
# - servicemonitors.monitoring.coreos.com
```

## Consequences

### Positive

- **ArgoCD가 잘하는 것에 집중**: Helm chart의 복잡한 sync는 ArgoCD에 위임
- **단순 자원은 빠르게**: CRD 등록 후 즉시 적용 가능
- **CRD 의존 명시**: ArgoCD App sync 완료를 명시적 선행 조건으로 박제

### Negative / Trade-off

- **자동화 빚 누적**: raw manifest 10여 개를 매 사이클 수동 apply (함정 #56 본질)
- **GitOps 순수성 부분 위반**: raw manifest는 Git 변경 감지 안 되고 수동 apply 필요
- **운영 사고 위험**: 잊은 manifest가 있으면 알아채기 어려움 (예: portfolio-ingress 누락 시 부하 시연 불가)

### Future Work — App-of-Apps 패턴 (Phase 5+)

ADR-0027의 한계를 해결하는 진화 방향:

```
root-app (parent Application — apps/of-apps)
├── portfolio-app (현재) — 앱 자원
├── portfolio-ingress — Ingress 자원
├── monitoring-stack — Prometheus + Grafana
├── monitoring-extras — PrometheusRule + AlertmanagerConfig + ServiceMonitor
├── logging-stack — EFK
├── tracing-stack — Jaeger
└── infrastructure-stack — ALB Controller, namespace, etc.
```

장점:
- 모든 자원 GitOps 관리 (raw manifest도 ArgoCD watch)
- 새 stack 추가 시 root-app에만 반영
- 환경별 분리(dev/staging/prod) 자연스러움

단점:
- 초기 구조 변경 비용 큼
- App-of-Apps 자체의 sync wave / dependency 관리 학습 필요

### Future Work — 자동화 스크립트

`scripts/post-apply.sh`로 raw manifest apply 일괄 자동화:

```bash
#!/bin/bash
# scripts/post-apply.sh — terraform apply 후 K8s 자원 자동 적용
set -e

cd ~/projects/portfolio-manifests

aws eks update-kubeconfig --region ap-northeast-2 --name portfolio-dev

# ALB Controller (terraform output에서 명령 추출 또는 직접)
helm install aws-load-balancer-controller eks/aws-load-balancer-controller ...

# namespace label
kubectl label namespace default elbv2.k8s.aws/pod-readiness-gate-inject=enabled --overwrite

# ConfigMap/Secret 3종 (terraform output 활용)
RDS_JDBC_URL=$(cd ../portfolio-infra/envs/dev && terraform output -raw rds_jdbc_url)
# ... (이하 생략)

# ArgoCD Application 등록
kubectl apply -f monitoring/kube-prometheus-stack/application.yaml
kubectl apply -f logging/fluent-bit/application.yaml
kubectl apply -f tracing/application.yaml

# CRD 등록 대기
kubectl wait --for=condition=Established crd/prometheusrules.monitoring.coreos.com --timeout=300s

# raw manifest 일괄
kubectl apply -f infrastructure/ingress/
kubectl apply -f monitoring/prometheus-rules.yaml
# ... 등
```

App-of-Apps 도입 시 이 스크립트 대부분 사라짐.

## References

- ADR-0018: Kustomize 채택
- ADR-0021: ArgoCD GitOps
- 함정 #46: ArgoCD Application 적용 직후 dependent 자원 적용 사고
- 함정 #56: infrastructure/ingress ArgoCD watch 안 됨

## Verification

이번 사이클(2026-05-02)에서 본 정책 적용 결과:

- [x] kube-prometheus-stack Application — Synced + Healthy
- [x] fluent-bit Application — Synced + Healthy
- [x] jaeger Application — Synced + Healthy
- [x] CRD 등록 후 PrometheusRule + AlertmanagerConfig + ServiceMonitor 적용 성공
- [x] infrastructure/ingress 누락 발견 → 즉시 apply로 복구 (함정 #56로 박제)