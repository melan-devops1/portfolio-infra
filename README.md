# portfolio-infra

`portfolio-app` 운영을 위한 AWS 인프라 — Terraform 1.14 + AWS Provider ~> 6.0.

> 전체 프로젝트 컨텍스트는 [portfolio-overview](https://github.com/melan-devops1/portfolio-overview)
> 참조.

## 구조

```
portfolio-infra/
├── bootstrap/        # 영구 자원 (한 번만 apply, 자체 로컬 state)
│   ├── main.tf                       Terraform state용 S3 버킷
│   ├── github_oidc.tf                GitHub Actions OIDC Provider
│   └── github_actions_*_role.tf      CI 자격용 IAM Role 2개
│                                     (terraform 용 / ECR 용 분리)
│
├── modules/          # 재사용 가능 모듈
│   ├── vpc/                          직접 작성: 3-tier subnet, Single NAT
│   ├── eks/                          공식 모듈 wrapping (K8s 1.33, Pod Identity)
│   ├── ecr/                          서비스별 리포 + IMMUTABLE + lifecycle + scan_on_push
│   ├── alb-controller-iam/           ALB Controller용 Pod Identity (ADR-0019)
│   ├── ebs-csi-iam/                  EBS CSI Driver용 Pod Identity
│   └── rds/                          PostgreSQL 15 단일 모듈 (intra subnet 격리)
│
├── envs/dev/         # 개발 환경 (매일 apply/destroy 사이클)
│   ├── main.tf                       위 6개 모듈 호출
│   ├── backend.tf                    S3 + use_lockfile (DynamoDB 미사용)
│   └── terraform.tfvars              ⚠️ gitignore 대상
│
└── docs/
    ├── adr/                          ADR-0011~0019, 0021~0029 (18개)
    ├── sla.md                        SLO/SLI 정의, 에러 예산
    ├── metrics-spec.md               RED 메트릭, PromQL, 알림 임계치
    ├── incident-report.md            사고 보고 양식
    ├── runbook/                      502 cascade / Alertmanager Slack / HPA boot race
    └── kibana/                       SLA 대시보드 saved object
```

## 사전 요구사항

- Terraform 1.14.x
- AWS CLI 2.34+, `aws configure` 완료
- WSL native 또는 Linux/macOS 파일시스템
  - `/mnt/c/...`(NTFS)에서 `terraform init` 시 chmod 에러 발생 → WSL `~/projects/`에서 작업

## 첫 부트스트랩 (한 번만)

```bash
cd bootstrap
terraform init
terraform apply

# CI 자격용 Role ARN을 GitHub Secrets에 등록
terraform output -raw github_actions_terraform_role_arn   # → portfolio-infra repo Secrets
terraform output -raw github_actions_ecr_role_arn         # → portfolio-app repo Secrets
```

bootstrap은 영구 자원 — destroy 하지 않는다.

## 일상 작업

### 인프라 띄우기

```bash
cd envs/dev
terraform init      # 첫 실행 시
terraform apply     # ~13분 (EKS 9분, RDS 3분 정도 비중)
```

### kubectl 설정

```bash
$(terraform output -raw configure_kubectl)
# 또는
aws eks update-kubeconfig --region ap-northeast-2 --name portfolio-dev
```

### 검증

```bash
kubectl get nodes                     # 2개 Ready
kubectl get pods -n kube-system       # CoreDNS, kube-proxy, VPC CNI, Pod Identity Agent

aws ecr describe-repositories --region ap-northeast-2 \
  --query 'repositories[*].repositoryName' --output table

# RDS endpoint 확인 (portfolio-manifests의 ConfigMap/Secret이 참조)
terraform output rds_endpoint
```

### 인프라 내리기

```bash
# K8s 리소스 먼저 정리 (LB/Ingress가 ENI 점유 시 destroy 실패 회피)
# 순서: ArgoCD Application → ArgoCD Ingress → ArgoCD → 앱 Ingress → 앱
# 자세한 순서는 portfolio-manifests/argocd/README.md 참조

# 그 다음 인프라 destroy (~10분)
cd envs/dev
terraform destroy
```

## 함정

작업하면서 만난 실제 이슈들. 새로 작업할 사람이 미리 알면 좋은 것들.

**EKS destroy/re-apply 후 kubeconfig 재발급 필수**
같은 클러스터 이름이라도 endpoint ID가 새로 발급된다.
```bash
aws eks update-kubeconfig --region ap-northeast-2 --name portfolio-dev
```

**EKS destroy 전 K8s LB/Ingress 먼저 정리**
`Service type=LoadBalancer`나 `Ingress`가 만든 AWS LB/ENI가 VPC를 점유 중이면
`terraform destroy`가 VPC 단계에서 실패한다. K8s 측 리소스를 먼저 `kubectl delete`.

**ECR 이미지 보존 시 destroy 동작**
default(`force_delete = false`)는 이미지 있으면 destroy 거부. 본 프로젝트의 `envs/dev`는
`force_delete = true`로 dev 환경에선 강제 삭제되도록 설정 (운영 환경은 default 유지 권장).

**RDS는 intra subnet (격리 자산)**
RDS는 NAT 없는 `intra subnet`에 배치. EKS 노드 SG에서만 5432 inbound 허용.
인터넷에 절대 노출되지 않음.

**`terraform.tfvars`는 gitignore 대상**
`owner_email` 등 환경별 값 포함. 새 워크스테이션 시작 시 수동 작성.

**AWS Provider 6.x deprecated 속성**
`data.aws_region.current.name` → `.region` (v7.0에서 제거 예정).
`aws_s3_bucket.region` → `bucket_region`.

## 비용

매일 apply/destroy 사이클로 운영비 절감. AWS Budgets $80/월 알림 설정.

| 자원 | 시간당 | 영구/일시 |
|---|---|---|
| EKS Control Plane | $0.10 | 일시 |
| EC2 노드 (t3.large × 2) | ~$0.21 | 일시 |
| NAT Gateway | $0.06 + 데이터 전송 | 일시 |
| RDS (db.t3.micro, single-AZ) | ~$0.02 | 일시 |
| **소계 (시간당)** | **~$0.39** | |
| S3 (state) + ECR (이미지) | <$1/월 | 영구 |

8시간 작업 시 ~$3.1 (+ NAT 데이터 전송 / RDS 스토리지 GB-month 별도).

## 설계 결정 (ADR)

총 18개. 자세한 근거는 각 ADR 파일 참조.

### Phase 2 — 인프라 기반

| | 결정 |
|---|---|
| [0011](./docs/adr/0011-terraform-state-backend.md) | S3 backend (versioning + AES256), bootstrap만 로컬 state |
| [0012](./docs/adr/0012-vpc-design.md) | VPC 직접 작성 + Single NAT + 3-tier subnet |
| [0013](./docs/adr/0013-s3-native-locking.md) | DynamoDB lock → S3 native locking (`use_lockfile`) |
| [0014](./docs/adr/0014-eks-official-module.md) | EKS는 공식 모듈 wrapping (`terraform-aws-modules/eks/aws ~> 21.0`) |
| [0015](./docs/adr/0015-pod-identity-over-irsa.md) | Pod Identity 채택 (IRSA supersede) |
| [0016](./docs/adr/0016-ecr-strategy.md) | ECR 서비스별 분리 + IMMUTABLE + scan_on_push + lifecycle |
| [0017](./docs/adr/0017-github-actions-oidc.md) | OIDC + Role 분리, 정적 자격증명 0개 |

### Phase 3 — K8s 배포 + GitOps

| | 결정 |
|---|---|
| [0018](./docs/adr/0018-kustomize-over-helm.md) | (앱 manifest) Kustomize, 3rd party는 Helm 가능 |
| [0019](./docs/adr/0019-alb-ingress.md) | AWS Load Balancer Controller + ALB Ingress |
| [0021](./docs/adr/0021-argocd-gitops.md) | ArgoCD GitOps (auto-sync + self-heal + ignoreDifferences) |

### Phase 4 — Observability + RDS

| | 결정 |
|---|---|
| [0022](./docs/adr/0022-observability-metrics.md) | kube-prometheus-stack + ServiceMonitor + PrometheusRule |
| [0023](./docs/adr/0023-rds-postgresql-and-configmap-secret.md) | RDS PostgreSQL 15 + ConfigMap/Secret 패턴 |
| [0024](./docs/adr/0024-efk-logging-stack.md) | EFK Stack (Elasticsearch + Fluent Bit + Kibana) |
| [0025](./docs/adr/0025-distributed-tracing-jaeger.md) | Jaeger + OpenTelemetry Java Agent (traces only) |
| [0026](./docs/adr/0026-alertmanager-matcher-strategy.md) | AlertmanagerConfig matcherStrategy=None |
| [0027](./docs/adr/0027-manifest-application-strategy.md) | Manifest 적용 전략 (Helm/kubectl/ArgoCD 경계) |
| [0028](./docs/adr/0028-log-platform-elasticsearch-over-splunk.md) | 로그 플랫폼 Elasticsearch 선택 (vs Splunk) |
| [0029](./docs/adr/0029-log-pipeline-fluent-bit-over-fluentd-logstash.md) | 로그 파이프라인 Fluent Bit 선택 (vs Fluentd/Logstash) |

## 운영 문서

| 문서 | 용도 |
|---|---|
| [docs/sla.md](./docs/sla.md) | SLO/SLI 정의 (99.9% / P99 2s / 5xx 5%), 에러 예산, 위반 대응 5단계 |
| [docs/metrics-spec.md](./docs/metrics-spec.md) | RED 메트릭, PromQL, PrometheusRule, AlertmanagerConfig |
| [docs/incident-report.md](./docs/incident-report.md) | 사고 보고 양식 |
| [docs/runbook/](./docs/runbook/) | 502 cascade / Alertmanager Slack 미발화 / HPA boot race |
| [docs/kibana/](./docs/kibana/) | SLA 대시보드 saved object (`.ndjson`) + 가이드 |
