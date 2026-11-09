terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Troque pelo output "bucket_state" do bootstrap.
  # use_lockfile faz o lock no próprio S3 (sem DynamoDB) — Terraform >= 1.10.
  backend "s3" {
    bucket       = "linuxtips-oidc-tfstate-907079643427"
    key          = "aula-oidc/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

# Repare: nenhuma access key aqui nem no repositório.
# O provider usa a cadeia padrão de credenciais, e a action
# configure-aws-credentials já deixou credenciais temporárias no ambiente.
provider "aws" {
  region = "us-east-1"
}
