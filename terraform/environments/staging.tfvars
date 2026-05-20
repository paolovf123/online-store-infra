environment                    = "staging"
aws_region                     = "us-east-1"
resource_suffix                = "stg01"
github_branch                  = "develop"
cloudfront_price_class         = "PriceClass_100"
cloudfront_logs_retention_days = 30
cloudfront_5xx_threshold       = 5
cloudfront_4xx_threshold       = 20
# alerts_email                 = "devops@example.com"  # opcional: confirmar suscripción desde el inbox

# Completar antes de aplicar:
# github_org           = "paolovf123"
# github_frontend_repo = "online-store-frontend"
#
# Si es el PRIMER entorno que aplicas en esta cuenta AWS, setear:
# create_github_oidc_provider = true
# En los siguientes entornos dejar en false (default) — el provider es uno solo por cuenta.
#
# Crear en SSM antes de terraform apply:
# aws ssm put-parameter --name "/online-store/staging/backend-url" --value "https://api-online-store-staging.azurewebsites.net" --type "String"
