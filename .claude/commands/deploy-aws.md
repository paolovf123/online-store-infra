---
description: Deploy AWS — Infra (S3 + CloudFront + IAM OIDC) vía Terraform. El deploy del frontend lo hace GitHub Actions
---

# Deploy AWS — Infra del Online Store

Aplica la infraestructura AWS de este repo. Argumento opcional:
- `/deploy-aws staging`
- `/deploy-aws production`
- `/deploy-aws` → pregunta al usuario

> Este skill **solo aplica Terraform**. El deploy del frontend lo dispara GitHub Actions del repo [online-store-frontend](https://github.com/paolovf123/online-store-frontend) al hacer push a `develop` (staging) o `main` (production).

---

## Contexto del proyecto

- **Frontend (otro repo):** Angular 20 → S3 + CloudFront. CI/CD en GitHub Actions usando OIDC para asumir el rol que crea este Terraform.
- **Backend:** Azure App Service. URL inyectada en build desde SSM Parameter Store.
- **Imágenes de productos:** Azure Blob Storage. Las URLs vienen embebidas en la respuesta del backend; el frontend las usa directo en `<img>`.
- **IaC:** Terraform en `terraform/`, tfvars por entorno.
- **Observabilidad:** SNS + CloudWatch alarms (5xx/4xx/no-traffic) y dashboard.

Entorno objetivo: **$ARGUMENTS** (si vacío, preguntar).

---

## Flujo a ejecutar

Actúa como asistente de despliegue **proactivo**: ejecuta las verificaciones con `Bash`, no solo imprimas comandos. Pide confirmación antes de operaciones que crean recursos o cuestan dinero.

### 0. Detectar entorno

Si `$ARGUMENTS` no está completo, pregunta al usuario `staging` o `production` antes de continuar. Guarda la elección como `ENV`.

### 1. Verificar identidad AWS

```bash
aws sts get-caller-identity
```

Confirma con el usuario que la cuenta y el ARN son los correctos. Guarda el `Account` ID como `ACCOUNT_ID`.

### 2. Pre-flight checks locales

| Check | Comando | Acción si falla |
|---|---|---|
| Archivos Terraform existen | Verificar `terraform/main.tf`, `terraform/variables.tf`, `terraform/outputs.tf`, `terraform/providers.tf` | Abortar — falta código |
| `github_org` y `github_frontend_repo` no comentados en tfvars | `grep -E '^[^#]*github_(org\|frontend_repo)' terraform/environments/<ENV>.tfvars` | Pedir al usuario los valores |
| Working tree limpio | `git status --short` | Recomendar commit antes (la infra debería deployarse desde código mergeado) |

Muestra resumen tabular y **pregunta al usuario si continúa**.

### 3. Verificar pre-requisitos de AWS (una sola vez por cuenta)

Comprueba en paralelo:

```bash
# Bucket tfstate
aws s3api head-bucket --bucket online-store-tfstate-$ACCOUNT_ID 2>&1

# Tabla DynamoDB lock
aws dynamodb describe-table --table-name online-store-tfstate-lock --region us-east-1 2>&1

# SSM parameter del entorno
aws ssm get-parameter --name /online-store/$ENV/backend-url --region us-east-1 2>&1

# OIDC provider de GitHub (puede existir o no)
aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[?contains(Arn, `token.actions.githubusercontent.com`)]' --output text
```

Para cada uno que falte, ofrece el comando de creación pero **pide confirmación** antes.

**A. Bucket S3 tfstate** (gratis):
```bash
aws s3api create-bucket --bucket online-store-tfstate-$ACCOUNT_ID --region us-east-1
aws s3api put-bucket-versioning --bucket online-store-tfstate-$ACCOUNT_ID --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket online-store-tfstate-$ACCOUNT_ID \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket online-store-tfstate-$ACCOUNT_ID \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

**B. Tabla DynamoDB lock** (PAY_PER_REQUEST):
```bash
aws dynamodb create-table --table-name online-store-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region us-east-1
```

**C. SSM parameter** — pedir la URL del backend Azure y **validarla antes**:

1. Pregunta al usuario la URL del backend (formato `https://<app>.azurewebsites.net`).
2. Valida que responde:
   ```bash
   nslookup <host>
   curl -sS -o /dev/null -w "HTTP %{http_code}\n" --max-time 10 <URL>/api/
   ```
3. Si DNS falla con `NXDOMAIN` o HTTP no es 2xx/3xx/401/403, **detente y avisa**. El backend no está desplegado o no responde. Confirma cómo continuar:
   - Esperar a desplegar el backend.
   - Guardar la URL igual (el deploy de Terraform sí funciona, pero el frontend desplegado fallará en runtime hasta que el backend esté arriba).
4. Solo si el usuario confirma, guarda:
   ```bash
   aws ssm put-parameter --name "/online-store/$ENV/backend-url" \
     --value "<URL>" --type "String" --region us-east-1
   ```

**D. OIDC provider**: si NO existe (el check anterior devolvió vacío):
- Editar el tfvar para setear `create_github_oidc_provider = true`.
- Avisar que en el segundo entorno hay que volver a setearlo en `false` (default).

Si SÍ existe, mantener en `false`. El TF lo referencia via data source.

### 3.5. Verificar dependencias Azure (backend + imágenes)

El frontend depende de recursos en Azure que **no se crean en este Terraform**. Antes del apply, recorre con el usuario esta checklist y márcalos OK / PENDIENTE.

**A. Backend App Service** — recuperar URL desde SSM y validar:
```bash
URL=$(aws ssm get-parameter --name "/online-store/$ENV/backend-url" --query 'Parameter.Value' --output text --region us-east-1)
curl -sS -o /dev/null -w "HTTP %{http_code} (%{time_total}s)\n" --max-time 10 "$URL/api/" || echo "❌ backend no responde"
```

**B. Storage Account con imágenes**

Preguntar al usuario:
1. ¿Existe el Storage Account y el container con las imágenes?
2. Modelo:
   - **Blobs públicos:** verificar con `curl -I "<URL_IMG_EJEMPLO>"` (debe dar 200).
   - **SAS URLs firmadas:** el backend incrusta token; verificar consultando `/api/productos` y revisando el formato de `imageUrl`.

Si los blobs son privados y el backend no firma SAS, el frontend mostrará el fallback `imagen_no_disponible.jpg`. Decidir antes de seguir.

**C. CORS del backend Azure**

Marcar como TODO post-apply — se completa cuando exista `cloudfront_url`.

**D. CORS del Storage Account** (solo si los blobs son privados con SAS y el `<img>` usa `crossorigin`)

Resume al usuario: ✅ listo / ⚠️ pendiente / ⛔ deal-breaker, y pide confirmación de continuar.

### 4. (Opcional) Configurar `alerts_email`

Si el usuario quiere recibir notificaciones de alarmas CloudFront, descomenta en el tfvar:
```hcl
alerts_email = "su-email@example.com"
```
Tras el apply, AWS envía un email de confirmación que hay que aceptar.

### 5. Inicializar Terraform

```bash
cd terraform

terraform init \
  -backend-config="bucket=online-store-tfstate-$ACCOUNT_ID" \
  -backend-config="key=online-store-$ENV.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=online-store-tfstate-lock" \
  -backend-config="encrypt=true"
```

### 6. Plan

```bash
terraform plan -var-file="environments/$ENV.tfvars" -out=tfplan
```

Resume al usuario los recursos clave:
- S3 buckets (frontend, cf-logs)
- CloudFront distribution con OAC y access logs
- IAM OIDC provider (si `create_github_oidc_provider = true`)
- IAM Role `online-store-gh-actions-<env>` con trust restringido al repo y rama del frontend
- SNS topic
- CloudWatch alarms (5xx, 4xx, opcional no-traffic) + dashboard

Verifica que **no haya `destroy`** inesperados. Pide aprobación explícita antes del apply.

### 7. Apply

```bash
terraform apply tfplan
```

### 8. Surfacear outputs

```bash
terraform output
```

Outputs importantes:
- `cloudfront_url` → URL pública del frontend
- `cloudfront_distribution_id`
- `s3_frontend_bucket`
- `github_actions_role_arn` ← **clave: secret en GitHub**
- `alerts_topic_arn`
- `cloudfront_logs_bucket`
- `cloudwatch_dashboard_url`

Muestra cada uno al usuario.

### 9. Acciones post-apply

Lista al usuario **en orden**, idealmente con una checklist:

1. **Configurar GitHub Environment del repo frontend** (Settings → Environments → `<ENV>`):
   | Tipo | Nombre | Valor |
   |---|---|---|
   | Secret | `AWS_DEPLOY_ROLE_ARN` | output `github_actions_role_arn` |
   | Variable | `S3_BUCKET` | output `s3_frontend_bucket` |
   | Variable | `CLOUDFRONT_DISTRIBUTION_ID` | output `cloudfront_distribution_id` |

   En `production`, además: **Required reviewers** = al menos 1 persona (bloqueará el deploy hasta aprobar).

2. **Confirmar SNS** (si configuró `alerts_email`): revisar inbox y aprobar la subscripción.

3. **CORS en Azure App Service**: agregar el dominio CloudFront (`cloudfront_url` sin barra final) a allowed origins. Portal Azure → App Service → API → CORS → Save.

4. **(Solo si los blobs son privados con SAS)** CORS del Storage Account: Storage Account → Resource sharing (CORS) → Blob service → Allowed origins = dominio CloudFront, GET, `*`, `*`, 3600.

5. **Disparar el primer deploy** del frontend:
   - Hacer push a la rama del entorno (`develop` para staging, `main` para production), o
   - Re-run del último workflow desde la pestaña Actions del repo frontend.

6. **Monitorear el workflow** en `https://github.com/<org>/online-store-frontend/actions`.

7. **En production**: GitHub mostrará un banner "Waiting for review" que un reviewer debe aprobar.

### 10. Smoke test

Cuando el workflow de Actions termine OK, ejecutar y reportar:

```bash
CF=$(cd terraform && terraform output -raw cloudfront_url)

# 1. CloudFront sirve el index.html
curl -sS -o /dev/null -w "index.html → HTTP %{http_code}\n" "$CF"

# 2. Abrir en navegador y verificar productos + imágenes
start "$CF"
```

En el navegador (DevTools → Network):
- `/api/productos` debe responder 200 → si no, revisar CORS del backend Azure.
- Las tarjetas deben mostrar fotos. Si todas tienen el fallback `imagen_no_disponible.jpg`:
  - Inspeccionar `<img>`, copiar el `src`.
  - `curl -I "<src>"`:
    - 403 → blob privado, cambiar access level o usar SAS.
    - 404 → la imagen no se subió al Storage Account.
    - Error CORS en consola → solo si el frontend usa `fetch`/`crossorigin`, configurar CORS del Storage Account.

---

## Errores frecuentes

| Error | Causa | Solución |
|---|---|---|
| `No value for required variable github_org` | tfvar incompleto | Descomentar `github_org` y `github_frontend_repo` |
| `AccessDenied` en S3 backend | Bucket tfstate no existe | Crear con el paso 3A |
| `ParameterNotFound` al leer SSM | Falta el parámetro del entorno | Crear con el paso 3C |
| `EntityAlreadyExists: arn:aws:iam::...:oidc-provider/token.actions.githubusercontent.com` | El provider ya existe en la cuenta | Setear `create_github_oidc_provider = false` y re-aplicar (lo referencia via data source) |
| `OpenIDConnectProvider not found` | `create_github_oidc_provider = false` pero el provider no existe | Setear en `true` solo en el primer entorno |
| Workflow falla con `Error: Could not assume role` | El sub del trust no coincide | Verificar que `github_org`, `github_frontend_repo` y `github_branch` del tfvar coinciden con repo y rama reales |
| Workflow falla en `aws ssm get-parameter` con AccessDenied | Policy del rol no cubre el path | Verificar `aws_iam_role_policy.github_actions_deploy` y nombre del parámetro SSM |
| Frontend carga pero `/api/productos` da `ERR_NAME_NOT_RESOLVED` | Backend Azure no existe (DNS NXDOMAIN) o SSM mal | `nslookup <host>` + revisar SSM. Si cambió de nombre, actualizar SSM y re-deployar el frontend (workflow lo re-inyecta) |
| Frontend carga pero llamadas API fallan con CORS | Falta CORS en Azure App Service | Agregar dominio CloudFront en App Service → CORS |
| Todas las imágenes muestran `imagen_no_disponible.jpg` | Backend no devuelve `imageUrl`, o URLs no accesibles | Inspeccionar `/api/productos`: si `imageUrl` es null, problema del backend. Si tiene URL pero `curl -I` da 403, blob privado |
| Imágenes en blob devuelven `403 PublicAccessNotPermitted` | Container privado | Storage Account → container → Change access level → `Blob` (anonymous read). Alternativa: que el backend firme SAS URLs |
| Imágenes fallan con error CORS en consola | El `<img>` usa `crossorigin` y el Storage Account no tiene CORS | Storage Account → CORS → agregar dominio CloudFront para Blob service |
| Alarma `5xxErrorRate` dispara tras deploy | Backend Azure caído o CORS mal | Revisar logs de Azure App Service y CORS |

---

## Notas de seguridad y costo

- Costo estimado en idle: ~$1-2/mes (CloudWatch alarms ~$0.30, S3 + CloudFront free tier).
- El bucket frontend es **privado** — solo CloudFront accede vía OAC.
- El rol OIDC está restringido por `sub` a un repo y rama específicos (`repo:<org>/<repo>:ref:refs/heads/<branch>`). No se puede asumir desde forks o PRs.
- Versioning + SSE habilitado en el bucket frontend; lifecycle limpia versiones obsoletas a 30 días.
- Access logs de CloudFront se retienen 30d staging / 90d production y se purgan automáticamente.
- Para `terraform destroy`: el bucket `cloudfront_logs` tiene `force_destroy = true`. El frontend NO — vaciarlo manualmente primero:
  ```bash
  aws s3 rm s3://$(terraform output -raw s3_frontend_bucket) --recursive
  ```
