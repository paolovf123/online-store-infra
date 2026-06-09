# ☁️ Online Store — Infraestructura (Terraform)

Infraestructura **AWS como código** del proyecto Online Store, gestionada con **Terraform** y un pipeline **GitOps** (`plan` en cada PR, `apply` al hacer merge). Crea el hosting del frontend (S3 + CloudFront), los roles **OIDC** que usan los GitHub Actions, la observabilidad (CloudWatch + SNS) y la configuración del backend (SSM).

El código del frontend vive en **[online-store-frontend](https://github.com/paolovf123/online-store-frontend)**; este repo solo provisiona la nube.

> **Cuenta AWS:** `492094933097` · **Región:** `us-east-1`

| Entorno | State key | CloudFront |
|---|---|---|
| 🟡 Staging | `online-store-staging.tfstate` | https://d1oy0fsyam6om9.cloudfront.net |
| 🟢 Production | `online-store-production.tfstate` | https://d2ielm05o2gs5q.cloudfront.net |

---

## 📐 Arquitectura

```
   GitHub Actions (repos frontend e infra)
        │  AssumeRoleWithWebIdentity (OIDC, token efímero)
        ▼
   ┌─────────────────────────────────────────────┐
   │  IAM OIDC Provider (global por cuenta)        │
   │  token.actions.githubusercontent.com          │
   └───────────────┬───────────────────────────────┘
                   │ confía en repos/entornos específicos
        ┌──────────┴───────────┬─────────────────────┐
        ▼                      ▼                     ▼
  deploy role            tf-plan (RO)          tf-apply (RW)
  (frontend)             (infra · PR)          (infra · merge)
        │
        │ s3 sync · cloudfront invalidation · ssm:GetParameter
        ▼
   ┌─────────────┐      ┌──────────────┐
   │ S3 frontend │ ───▶ │  CloudFront   │ ───▶  Usuarios
   │ (privado)   │ OAC  └──────────────┘
   └─────────────┘
   ┌─────────────┐   ┌──────────────────────┐   ┌──────────┐
   │ S3 cf-logs  │   │ CloudWatch dashboard  │   │ SSM       │
   │ (access log)│   │ + alarmas 4xx/5xx/0   │──▶│ backend-  │
   └─────────────┘   └──────────┬───────────┘   │ url       │
                                ▼                └──────────┘
                            SNS topic ──▶ email (opcional)
```

### Recursos por entorno

| Recurso | Para qué |
|---|---|
| `S3 *-frontend-<env>` | Bundle Angular (privado, acceso solo por CloudFront vía OAC) |
| `S3 *-cf-logs-<env>` | Access logs de CloudFront (lifecycle de retención) |
| `CloudFront` | CDN, HTTPS, routing de la SPA |
| `IAM OIDC provider` | Confianza federada con GitHub (global, uno por cuenta) |
| `IAM role *-gh-actions-<env>` | Permisos mínimos para que el **frontend** deploye |
| `SSM /online-store/<env>/backend-url` | URL del backend que el frontend hornea en build |
| `CloudWatch dashboard + alarmas` | Salud de CloudFront (4xx, 5xx, sin tráfico) |
| `SNS topic` | Notificación de alarmas (email opcional) |

---

## 🔐 Modelo de seguridad — OIDC, cero llaves estáticas

No existe ningún `AWS_ACCESS_KEY` guardado: GitHub firma un token OIDC efímero y AWS lo cambia por credenciales temporales. Hay **tres roles**, cada uno con el mínimo privilegio para su tarea:

| Rol | Lo asume | Permisos | Confianza (claim `sub`) |
|---|---|---|---|
| `online-store-gh-actions-<env>` | CD del **frontend** | s3 sync al bucket, invalidar CloudFront, leer SSM | `repo:.../online-store-frontend:environment:<env>` |
| `online-store-tf-plan` | CI de **infra** (en PR) | **ReadOnlyAccess** | `repo:.../online-store-infra:pull_request` |
| `online-store-tf-apply` | CD de **infra** (en merge) | PowerUserAccess + IAMFullAccess | `repo:.../online-store-infra:environment:tf-<env>` |

El `apply` de production siempre queda detrás de un **required reviewer** (GitHub Environment `tf-production`).

---

## 🔄 CI/CD GitOps (este repo)

### 🔍 CI — [`ci.yml`](.github/workflows/ci.yml) · en cada PR a `main` (que toque `terraform/**`)

```
   Format  ───▶  Validate  ───▶  Plan (staging) + Plan (production)
```

`terraform fmt` → `validate` → `plan` contra el state real (rol **solo lectura**) y **publica el plan como comentario del PR** para revisarlo antes de mergear.

### 🚢 CD — [`cd.yml`](.github/workflows/cd.yml) · en push a `main`

```
   Apply staging (automático)  ───▶  Apply production (con aprobación)
```

`apply` de staging automático; el de production se **pausa** esperando aprobación (environment `tf-production`). Ambos asumen el rol de escritura por OIDC.

---

## 🗂️ Estructura

```
terraform/
├── main.tf              # S3, CloudFront, OAC, IAM/OIDC, CloudWatch, SNS, SSM
├── variables.tf         # variables de entrada (incluye backend_url)
├── outputs.tf           # ARNs, URLs, IDs que consume el frontend
├── providers.tf         # provider AWS + backend "s3"
└── environments/
    ├── staging.tfvars
    └── production.tfvars
```

---

## 🧱 Backend de estado remoto (bootstrap — una vez por cuenta)

El state vive en S3 con lock en DynamoDB (ya creados en esta cuenta):

```bash
aws s3 mb s3://online-store-tfstate-492094933097 --region us-east-1
aws s3api put-bucket-versioning --bucket online-store-tfstate-492094933097 \
  --versioning-configuration Status=Enabled
aws dynamodb create-table --table-name online-store-tflock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region us-east-1
```

---

## ▶️ Aplicar manualmente (alternativa al CD)

```bash
cd terraform

terraform init \
  -backend-config="bucket=online-store-tfstate-492094933097" \
  -backend-config="key=online-store-<env>.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=online-store-tflock" \
  -backend-config="encrypt=true"

terraform plan  -var-file="environments/<env>.tfvars" -out=tfplan
terraform apply tfplan
```

> **Primer entorno en la cuenta:** poner `create_github_oidc_provider = true` en su `.tfvars` (el OIDC provider es **global**, uno por cuenta). En los demás entornos queda en `false` y se referencia vía *data source*.

---

## 📤 Outputs

| Output | Para qué |
|---|---|
| `cloudfront_url` | URL pública del frontend |
| `cloudfront_distribution_id` | → variable `CLOUDFRONT_DISTRIBUTION_ID` en el repo frontend |
| `s3_frontend_bucket` | → variable `S3_BUCKET` en el repo frontend |
| `github_actions_role_arn` | → secret `AWS_DEPLOY_ROLE_ARN` en el repo frontend |
| `cloudwatch_dashboard_url` | Link al dashboard de métricas |
| `alerts_topic_arn` | Para suscripciones adicionales al SNS |

---

## ⚙️ URL del backend (SSM, gestionada por Terraform)

El parámetro `/online-store/<env>/backend-url` se crea con el recurso `aws_ssm_parameter.backend_url` a partir de la variable `backend_url` (definida en cada `.tfvars`). Hoy es un *placeholder* (`https://placeholder.invalid`) hasta que exista el backend real.

**Para cambiar el backend:** editar `backend_url` en `environments/<env>.tfvars` → PR → merge. El CD aplica el cambio. *(No se setea a mano con `aws ssm put-parameter`.)*

---

## 💰 Costo estimado

~**$1–2/mes** en reposo: las alarmas de CloudWatch (~$0.30) y S3/CloudFront dentro del *free tier* para tráfico bajo. No hay CodePipeline/CodeBuild — el CI/CD es GitHub Actions + OIDC (gratis para repos públicos).

---

## 🧹 `terraform destroy`

```bash
terraform destroy -var-file="environments/<env>.tfvars"
```

- El bucket `*-frontend-<env>` **no** tiene `force_destroy`; vaciarlo primero:
  ```bash
  aws s3 rm s3://$(terraform output -raw s3_frontend_bucket) --recursive
  ```
- Si este entorno creó el OIDC provider (`create_github_oidc_provider = true`), al destruirlo se borra y los otros entornos que lo referencian fallarán. Mover el flag a otro entorno y aplicarlo antes de destruir.
