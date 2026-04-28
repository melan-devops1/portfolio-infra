# ADR-0013: Terraform State Lock — DynamoDB → S3 Native Locking 전환

## Status
Accepted (2026-04-28). **Supersedes** ADR-0011 (S3 + DynamoDB Lock 부분).

## Context

ADR-0011에서 Terraform state 백엔드를 S3 + DynamoDB lock 패턴으로 부트스트랩했다.
이 패턴은 Terraform 1.10 이전까지 사실상 표준이었다.

`envs/dev`에서 첫 `terraform apply` 실행 시 다음 경고가 발생했다:

```
Warning: Deprecated Parameter
The parameter "dynamodb_table" is deprecated. Use parameter "use_lockfile" instead.
```

배경:
- Terraform 1.10 (2024년 12월): S3 native locking (`use_lockfile`) 실험적 도입
- Terraform 1.11 (2025년 초): GA 전환, `dynamodb_table` deprecated 명시
- Terraform 1.14 (2026년 4월, 본 프로젝트 사용 버전): deprecated warning 표시 중,
  향후 minor 버전에서 완전 제거 예정

S3 native locking이 가능해진 기술적 배경:
- 2020년 12월부터 모든 S3 버킷이 strong read-after-write consistency 보장
- `If-None-Match` 헤더 기반 conditional write 지원 (lock 객체를 "존재하지 않을 때만 생성")
- 위 두 가지로 별도 lock 서비스 없이 S3 자체에서 optimistic locking 구현 가능

## Decision

DynamoDB 기반 lock을 제거하고 S3 native locking (`use_lockfile = true`)으로 전환한다.

### 구체 변경 사항
1. **`bootstrap/main.tf`**: `aws_dynamodb_table.tfstate_lock` 리소스 삭제
2. **`bootstrap/outputs.tf`**: `tfstate_lock_table_name` 출력 삭제
3. **`bootstrap/main.tf`**: S3 버킷에 lifecycle 정책 추가
   - 잦은 lock 파일 PUT/DELETE로 인해 noncurrent version이 누적되는 것을 7일 후 자동 정리
   - delete marker도 자동 정리
4. **`envs/dev/backend.tf`**: `dynamodb_table` 라인 → `use_lockfile = true`로 교체

### 마이그레이션 절차
1. `envs/dev`에서 사용 중인 lock이 있다면 해제 (`terraform force-unlock <ID>`)
2. `bootstrap/`에서 새 코드 적용 → DynamoDB 테이블 삭제, lifecycle 정책 추가
3. `envs/dev/backend.tf` 수정
4. `envs/dev`에서 `terraform init -reconfigure` 실행 → 새 backend 설정 인식
5. 평소처럼 `terraform plan` / `apply`

## Consequences

### 긍정
+ deprecated warning 제거 (PROJECT_CONTEXT.md "현행 표준만 사용" 원칙 준수)
+ 관리 자원 1개 감소 (DynamoDB 테이블 불필요)
+ DynamoDB IAM 권한 정책 불필요 → IAM 정책 더 간단
+ DynamoDB PAY_PER_REQUEST 과금 항목 제거 (실사용 시 수 센트지만 정리됨)
+ 향후 Terraform 메이저 업그레이드 시 자동 호환

### 부정
- 한 가지 신경 써야 할 점: lock 파일 버전 누적 → lifecycle 정책으로 해결 (코드에 명시)
- 매우 높은 동시성 환경(다수 파이프라인 동시 실행)에선 DynamoDB가 미세하게 더 빠를 수 있음.
  본 프로젝트는 1인 환경이라 무관.

### 운영 환경 고려사항
운영 도입 시:
- Versioning + lifecycle 조합으로 lock 파일 버전 누적 비용 < $0.01/월 수준
- 외부 도구가 DynamoDB lock 테이블에 의존하는 경우(예: 외부 lock 모니터링 시스템)
  사전 영향도 평가 필요

## Alternatives Considered

### Hybrid (DynamoDB + S3 lockfile 동시 사용)
- HashiCorp 공식 마이그레이션 가이드의 "안전한 전환" 옵션
- 두 lock 모두 획득해야 작업 진행 → 안전성 ⬆️ 그러나 양쪽 모두 관리 필요
- 본 프로젝트는 1인 환경이고 부트스트랩 직후라 lock 충돌 위험 없음 → 한 번에 전환

### DynamoDB 유지
- OpenTofu(Terraform fork)는 DynamoDB locking을 deprecate하지 않음
- 그러나 본 프로젝트는 Terraform 사용. 향후 제거 확정인 기능 유지는 PROJECT_CONTEXT.md
  "deprecated 사용 금지" 원칙과 충돌

## References
- HashiCorp 공식: S3 backend documentation
  https://developer.hashicorp.com/terraform/language/backend/s3
- HashiCorp 디자인 노트: S3 native state locking
  https://www.bschaatsbergen.com/s3-native-state-locking
- ADR-0011: 본 ADR이 supersede하는 원본 결정
