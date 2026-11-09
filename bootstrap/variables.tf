variable "region" {
  type        = string
  description = "Região AWS"
  default     = "us-east-1"
}

variable "github_org" {
  type        = string
  description = "Usuário ou organização dona do repositório no GitHub"
}

variable "github_repo" {
  type        = string
  description = "Nome do repositório (sem a organização)"
}

variable "branch" {
  type        = string
  description = "Branch que pode fazer apply"
  default     = "main"
}

variable "prefixo" {
  type        = string
  description = "Prefixo dos recursos que o pipeline pode criar"
  default     = "linuxtips-oidc"
}

variable "criar_provider_oidc" {
  type        = bool
  description = "Feature flag: false reaproveita o OIDC provider do GitHub que já existe na conta"
  default     = true
}
