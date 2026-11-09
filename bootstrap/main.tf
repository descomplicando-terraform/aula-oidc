data "aws_caller_identity" "atual" {}

locals {
  # O GitHub coloca o ID numérico do dono e do repo no sub:
  #   repo:gomex@95132/aula-oidc@1451497761:ref:refs/heads/main
  # O * (com StringLike) aceita qualquer ID e deixa só os nomes no código.
  repo = "${var.github_org}@*/${var.github_repo}@*"
}

# ---------------------------------------------------------------------------
# 1. Provedor de identidade OIDC
#
# Diz para a AWS: "confie em tokens assinados por token.actions.githubusercontent.com
# desde que a audiência seja sts.amazonaws.com".
# Existe apenas UM por conta para essa URL. Se outro projeto já criou,
# criar_provider_oidc = false reaproveita o existente via data source
# (importar faria o destroy da aula apagar o provider do outro projeto).
#
# thumbprint_list não é mais necessário: a AWS valida o certificado do GitHub
# pela sua própria lista de CAs confiáveis.
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count = var.criar_provider_oidc ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.criar_provider_oidc ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = var.criar_provider_oidc ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# ---------------------------------------------------------------------------
# 2. Bucket do state remoto
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  bucket = "${var.prefixo}-tfstate-${data.aws_caller_identity.atual.account_id}"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# 3. Role de PLAN — assumida só em pull requests
#
# O "sub" do token é o que diferencia quem está pedindo acesso:
#   pull request        -> repo:ORG/REPO:pull_request
#   push na branch main -> repo:ORG/REPO:ref:refs/heads/main
#   job com environment -> repo:ORG/REPO:environment:NOME
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "confia_plan" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.repo}:pull_request"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "${var.prefixo}-github-plan"
  assume_role_policy   = data.aws_iam_policy_document.confia_plan.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ---------------------------------------------------------------------------
# 4. Role de APPLY — assumida só por push na branch protegida
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "confia_apply" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.repo}:ref:refs/heads/${var.branch}"]
    }
  }
}

resource "aws_iam_role" "apply" {
  name                 = "${var.prefixo}-github-apply"
  assume_role_policy   = data.aws_iam_policy_document.confia_apply.json
  max_session_duration = 3600
}

# Menor privilégio: o pipeline só mexe em buckets com o prefixo da aula.
# Em produção, troque pelo conjunto de permissões que seu código realmente usa.
data "aws_iam_policy_document" "apply" {
  statement {
    sid     = "RecursosDaAula"
    actions = ["s3:*"]
    resources = [
      "arn:aws:s3:::${var.prefixo}-app-*",
      "arn:aws:s3:::${var.prefixo}-app-*/*",
    ]
  }
}

resource "aws_iam_role_policy" "apply" {
  name   = "recursos-da-aula"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply.json
}

# ---------------------------------------------------------------------------
# 5. Acesso ao state — as duas roles precisam ler o state e criar o lock
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "state" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

resource "aws_iam_role_policy" "state_plan" {
  name   = "tfstate"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.state.json
}

resource "aws_iam_role_policy" "state_apply" {
  name   = "tfstate"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.state.json
}
