data "aws_caller_identity" "atual" {}

# O nome precisa começar com "linuxtips-oidc-app-": é o único padrão
# que a role de apply tem permissão para criar.
resource "aws_s3_bucket" "app" {
  bucket = "linuxtips-oidc-app-${data.aws_caller_identity.atual.account_id}"

  tags = {
    criado_por = "github-actions-oidc"
  }
}

output "quem_sou_eu" {
  description = "Mostra que o Terraform rodou com a role assumida via OIDC"
  value       = data.aws_caller_identity.atual.arn
}
