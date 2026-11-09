# aula-oidc

Aula LINUXtips: GitHub Actions na AWS via OIDC, sem credenciais guardadas.

O pipeline deste repo roda `terraform plan` e `terraform apply` na AWS sem nenhuma
access key, secret ou variável configurada no GitHub. A cada execução o job pede
um token OIDC ao GitHub e troca esse token por credenciais temporárias de 1 hora.

```
.
├── bootstrap/                       # roda UMA vez, da sua máquina, com credencial de admin
├── infra/                           # o que o pipeline aplica
└── .github/workflows/
    ├── terraform.yml                # plan no PR, apply no push na main
    └── raio-x-token.yml             # mostra o conteúdo do token OIDC (rodar à mão)
```

## Requisitos

Antes do pipeline funcionar, o seguinte precisa estar pronto:

**Na sua máquina (só para o bootstrap)**

- Terraform **1.10 ou mais novo**: o backend usa `use_lockfile`, que faz o lock no
  próprio S3, sem DynamoDB.
- AWS CLI com uma credencial que possa criar recursos de IAM e S3 na conta
  (`aws sso login` ou `aws configure`). Ela só é usada no bootstrap. Depois disso,
  o GitHub nunca precisa dela.

**No GitHub**

- O repositório com o GitHub Actions habilitado.
- Nenhum secret e nenhuma variável. A única exigência está no próprio workflow:
  `permissions: id-token: write`. Sem isso o job não consegue pedir o token.

**Na AWS**

- O bootstrap aplicado na conta (próxima seção).
- Os valores que o bootstrap gera copiados para `infra/providers.tf` e para
  `.github/workflows/terraform.yml` (ver [Passo a passo](#passo-a-passo)).

## O que o bootstrap cria

O bootstrap cria tudo o que a pasta `infra/` e o workflow precisam para rodar.
São três grupos de recursos.

### 1. O provedor de identidade OIDC

| Recurso | Para quê |
|---|---|
| `aws_iam_openid_connect_provider` para `https://token.actions.githubusercontent.com`, com audiência `sts.amazonaws.com` | Faz a AWS confiar em tokens assinados pelo GitHub. Sem ele, o `AssumeRoleWithWebIdentity` do workflow falha com `No OpenIDConnect provider found`. |

Só pode existir **um** provider por conta para essa URL. Se a conta já tiver um,
criado por outro projeto, use `criar_provider_oidc = false`. Assim o bootstrap
reaproveita o existente em vez de tentar criar outro. Para conferir:

```bash
aws iam list-open-id-connect-providers
```

Não use `terraform import` nesse provider: o `destroy` da aula apagaria um recurso
de que outros projetos dependem.

### 2. O bucket do state remoto

| Recurso | Para quê |
|---|---|
| `aws_s3_bucket` `linuxtips-oidc-tfstate-<ACCOUNT_ID>` | Guarda o `terraform.tfstate` da pasta `infra/`. Cada job do Actions roda numa máquina nova, então o state não pode ficar local. |
| `aws_s3_bucket_versioning` | Mantém versões anteriores do state, para recuperar se algo der errado. |
| `aws_s3_bucket_public_access_block` | Bloqueia qualquer acesso público. O state pode conter dados sensíveis. |

Esse bucket é o mesmo nome configurado no `backend "s3"` de `infra/providers.tf`.

### 3. As duas roles que o pipeline assume

Cada role tem duas partes: a **trust policy** decide *quem* pode assumir, e as
**permissões** decidem *o que* pode fazer depois de entrar.

| | `linuxtips-oidc-github-plan` | `linuxtips-oidc-github-apply` |
|---|---|---|
| Usada pelo job | `plan` (em pull request) | `apply` (em push na `main`) |
| Trust policy: `aud` | `sts.amazonaws.com` | `sts.amazonaws.com` |
| Trust policy: `sub` | `repo:ORG@*/REPO@*:pull_request` | `repo:ORG@*/REPO@*:ref:refs/heads/main` |
| Permissões na conta | `ReadOnlyAccess`: o plan precisa ler o estado real dos recursos | `s3:*` só em buckets `linuxtips-oidc-app-*`: é o único recurso que `infra/` cria |
| Permissões no state | `ListBucket`, `GetObject`, `PutObject` e `DeleteObject` no bucket de state | as mesmas |
| Duração da sessão | 1 hora | 1 hora |

O acesso ao state vale para as duas roles porque até o `plan` grava o arquivo de
lock (`terraform.tfstate.tflock`) e o apaga no final.

**Por que o `@*` no `sub`?** O GitHub coloca o ID numérico do dono e do repo no
token, por exemplo `repo:gomex@95132/aula-oidc@1451497761:pull_request`. O `*`,
com `StringLike`, aceita qualquer ID e deixa só os nomes no código. O custo é que
um repo apagado e recriado com o mesmo nome também é aceito. Para barrar isso,
troque o `*` pelos IDs reais.

## Passo a passo

### 1. Rodar o bootstrap

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # preencha github_org e github_repo
terraform init
terraform apply
```

O state do bootstrap fica **local**, de propósito: ele cria o bucket que guarda o
state do pipeline, então não pode guardar o próprio state nele. Não apague o
`terraform.tfstate` dessa pasta. É com ele que você faz o `destroy` depois.

Ao final, anote os outputs:

```
account_id     = "123456789012"
bucket_state   = "linuxtips-oidc-tfstate-123456789012"
role_apply_arn = "arn:aws:iam::123456789012:role/linuxtips-oidc-github-apply"
role_plan_arn  = "arn:aws:iam::123456789012:role/linuxtips-oidc-github-plan"
```

### 2. Copiar os outputs para o repo

| Output | Onde colocar |
|---|---|
| `bucket_state` | `infra/providers.tf`, campo `bucket` do `backend "s3"` |
| `role_plan_arn` | `.github/workflows/terraform.yml`, variável `ROLE_PLAN` em `env` |
| `role_apply_arn` | `.github/workflows/terraform.yml`, variável `ROLE_APPLY` em `env` |

O ARN de uma role não é segredo: sozinho, ele não dá acesso a nada. Por isso ele
fica direto no workflow, e não em um secret.

### 3. Abrir um PR mexendo em `infra/`

O workflow só roda quando muda algo em `infra/` ou no próprio `terraform.yml`.

- No PR, o job `plan` assume a role de plan e mostra o que vai mudar.
- No merge, o job `apply` assume a role de apply e cria o bucket
  `linuxtips-oidc-app-<ACCOUNT_ID>`.

O passo "Quem sou eu?" de cada job mostra a role assumida e a sessão
`gh-<run_id>`, a mesma que aparece no CloudTrail.

## O que precisa bater para não quebrar

Se o pipeline falhar no passo de credenciais, quase sempre é uma destas:

| Sintoma | Causa provável |
|---|---|
| `Could not load credentials` / falta `ACTIONS_ID_TOKEN_REQUEST_URL` | O workflow perdeu o `permissions: id-token: write` |
| `No OpenIDConnect provider found` | O bootstrap não rodou nesta conta |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | O `sub` não bate: repo, dono ou branch diferentes do `terraform.tfvars` do bootstrap |
| `NoSuchBucket` ou `AccessDenied` no `terraform init` | O `bucket` do backend não é o `bucket_state` do bootstrap |
| `AccessDenied` ao criar o bucket no apply | O nome do bucket em `infra/main.tf` não começa com `linuxtips-oidc-app-` |

Se você mudar o `prefixo` ou a `branch` no bootstrap, mude também os nomes em
`infra/` e o trigger do workflow.

## Limpeza

```bash
# 1. a infra (com credencial de admin, na sua máquina)
cd infra && terraform init && terraform destroy

# 2. o bootstrap por último. O bucket de state precisa estar vazio,
#    inclusive as versões antigas, senão o destroy falha.
cd ../bootstrap && terraform destroy
```
