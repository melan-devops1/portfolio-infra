###############################################################################
# GitHub Actions OIDC Identity Provider
#
# OIDC(OpenID Connect)는 GitHub Actions가 워크플로우 실행 중 동적으로 발급하는 JWT를
# AWS IAM이 신뢰하게 만드는 표준 프로토콜.
#
# 이 Provider 1개만 있으면 모든 IAM Role의 트러스트 정책에서 재사용 가능.
# AWS 계정당 1개만 필요해서 bootstrap에 둔다 (모든 환경 공유).
#
# 변경 이력:
#   v1: 정적 thumbprint 1개 사용
#   v2 (현재): data "tls_certificate"로 동적 추출
#              2024-12 AWS Go SDK 업데이트 후 thumbprint는 사실상 무시되지만,
#              terraform AWS provider 6.x는 여전히 빈 리스트를 거부할 수 있어 안전책으로 추출.
###############################################################################

# GitHub OIDC discovery 엔드포인트에서 인증서 동적 추출
# (정적 thumbprint를 박는 구식 패턴 회피 — 인증서 갱신 시 코드 변경 불필요)
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  # client_id_list = "Audience". GitHub Actions가 sts.amazonaws.com을 audience로 토큰 발급.
  client_id_list = ["sts.amazonaws.com"]

  # 동적 추출된 thumbprint
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]

  tags = {
    Name = "github-actions-oidc"
  }
}
