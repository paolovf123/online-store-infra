# Online Store — Infrastructure

Infraestructura AWS (Terraform) para el frontend del proyecto Online Store. El código frontend vive en el repo [online-store-frontend](https://github.com/paolovf123/online-store-frontend); este repo solo crea los recursos AWS y el rol OIDC que sus GitHub Actions van a usar para deployar.

---

## Arquitectura AWS

```
GitHub Actions (repo frontend)
    │ assume role (OIDC)
    ▼
[IAM Role online-store-gh-actions-<env>]
    │ s3:PutObject, cloudfront:CreateInvalidation, ssm:GetParameter
    ▼
[S3 frontend bucket] ──> [CloudFront] ──> Usuarios

[CloudWatch alarms (5xx / 4xx / no-traffic)] ──> [SNS topic] ──> email
```

| Recurso | Para qué |
|---|---|
| S3 `*-frontend-<env>` | Bundle Angular (privado, OAC) |
| S3 `*-cf-logs-<env>` | Access logs de CloudFront |
| CloudFront | CDN + HTTPS + SPA routing |
| IAM OIDC provider | Confianza con `token.actions.githubusercontent.com` |
| IAM Role `*-gh-actions-<env>` | Permisos mínimos para que el workflow deploye |
| SNS topic + alarmas | Salud de CloudFront |
| CloudWatch dashboard | Requests, error rate, bytes |

> **Lo que NO está aquí:** CodePipeline, CodeBuild, CodeStar Connections. El CI/CD se movió a GitHub Actions; el rol OIDC reemplaza esos servicios.

---

## Pre-requisitos (una sola vez por cuenta AWS)

```bash
# Bucket para el state remoto de Terraform
aws s3 mb s3://online-store-tfstate-<ACCOUNT_ID> --region us-east-1
aws s3api put-bucket-versioning \
  --bucket online-store-tfstate-<ACCOUNT_ID> \
  --versioning-configuration Status=Enabled

# Tabla DynamoDB para el lock
aws dynamodb create-table \
  --table-name online-store-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1

# SSM parameter por entorno con la URL del backend Azure
aws ssm put-parameter \
  --name "/online-store/staging/backend-url" \
  --value "https://api-online-store-staging.azurewebsites.net" \
  --type "String"

aws ssm put-parameter \
  --name "/online-store/production/backend-url" \
  --value "https://api-online-store.azurewebsites.net" \
  --type "String"
```

---

## Aplicar

Usa la skill integrada de Claude Code:

```
/deploy-aws staging
/deploy-aws production
```

O manualmente:

```bash
cd terraform

terraform init \
  -backend-config="bucket=online-store-tfstate-<ACCOUNT_ID>" \
  -backend-config="key=online-store-<env>.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=online-store-tfstate-lock" \
  -backend-config="encrypt=true"

terraform plan -var-file="environments/<env>.tfvars" -out=tfplan
terraform apply tfplan
```

> **Primer entorno aplicado:** setear `create_github_oidc_provider = true` en el tfvar. En los siguientes entornos dejarlo en false (el OIDC provider es global por cuenta).

---

## Outputs relevantes

| Output | Para qué |
|---|---|
| `cloudfront_url` | URL pública del frontend |
| `cloudfront_distribution_id` | Setear como variable `CLOUDFRONT_DISTRIBUTION_ID` en GitHub Environment |
| `s3_frontend_bucket` | Setear como variable `S3_BUCKET` en GitHub Environment |
| `github_actions_role_arn` | Setear como secret `AWS_DEPLOY_ROLE_ARN` en GitHub Environment |
| `cloudwatch_dashboard_url` | Link al dashboard |
| `alerts_topic_arn` | Para suscripciones adicionales al SNS |

---

## Después de aplicar (en el repo frontend)

Configurar en [github.com/paolovf123/online-store-frontend/settings/environments](https://github.com/paolovf123/online-store-frontend/settings/environments):

1. Environment `staging`:
   - Secret `AWS_DEPLOY_ROLE_ARN` = output `github_actions_role_arn`
   - Variable `S3_BUCKET` = output `s3_frontend_bucket`
   - Variable `CLOUDFRONT_DISTRIBUTION_ID` = output `cloudfront_distribution_id`
2. Environment `production`: lo mismo, con los outputs del apply de production. Agregar **Required reviewers** para que el deploy a main pida aprobación manual.

Luego, en Azure App Service → CORS, agregar la URL CloudFront como allowed origin.

---

## Costo estimado

~$1-2/mes en idle (CloudWatch alarms ~$0.30, S3 + CloudFront en free tier para tráfico bajo). Sin costo de CodePipeline porque ya no existe.

---

## `terraform destroy`

```bash
terraform destroy -var-file="environments/<env>.tfvars"
```

- `cloudfront_logs` y `frontend` buckets — el primero tiene `force_destroy = true`. El segundo NO; hay que vaciarlo manualmente antes:
  ```bash
  aws s3 rm s3://$(terraform output -raw s3_frontend_bucket) --recursive
  ```
- El OIDC provider (si lo creó este entorno con `create_github_oidc_provider = true`) se borra. Si hay otros entornos que lo referencian via data source, fallarán. Solución: mover el flag al siguiente entorno y aplicar antes de destruir.
