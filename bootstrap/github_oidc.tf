###############################################################################
# GitHub Actions OIDC Identity Provider
#
# OIDC(OpenID Connect)는 GitHub Actions가 워크플로우 실행 중 동적으로 발급하는 JWT를
# AWS IAM이 신뢰하게 만드는 표준 프로토콜.
#
# 한 AWS 계정에는 같은 URL(token.actions.githubusercontent.com)을 가진 OIDC Provider가
# 단 1개만 존재할 수 있다. 본 계정엔 다른 프로젝트가 이미 동일 Provider를 만들어둔
# 상태이므로 resource로 새로 생성하면 409 EntityAlreadyExists로 실패한다.
#
# 따라서 resource 대신 data source로 기존 Provider를 참조한다.
#   · ClientIDList=["sts.amazonaws.com"]  ← 본 코드의 Role Trust 정책과 호환 확인됨
#   · 다른 프로젝트가 Provider의 "주인". 본 모듈은 Role 두 개만 소유.
#   · Role의 Trust 조건의 sub로 레포(portfolio-infra / portfolio-app)만 한정해
#     다른 프로젝트의 워크플로우가 본 Role을 가로채는 것을 차단한다.
#
# 운영 환경에서 본 코드를 다른 신규 AWS 계정에 배포할 경우:
#   1) 해당 계정에 GitHub Actions OIDC Provider가 없으면 → 이 파일을 resource로 되돌림
#   2) 이미 있으면 → 그대로 data source로 사용
###############################################################################

data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

# resource "aws_iam_openid_connect_provider" "github_actions" {
#   url = "https://token.actions.githubusercontent.com"
#
#   # client_id_list = "Audience". GitHub Actions가 sts.amazonaws.com을 audience로 토큰 발급.
#   client_id_list = ["sts.amazonaws.com"]
#
#   # 동적 추출된 thumbprint
#   thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
#
#   tags = {
#     Name = "github-actions-oidc"
#   }
# }