terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# O bootstrap roda UMA vez, da máquina de quem administra a conta
# (aws sso login / aws configure). É o "ovo" antes da "galinha":
# depois disso o GitHub nunca mais precisa de credencial nenhuma.
provider "aws" {
  region = var.region
}
