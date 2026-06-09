environment                    = "staging"
aws_region                     = "us-east-1"
resource_suffix                = "stg01"
github_branch                  = "develop"
cloudfront_price_class         = "PriceClass_100"
cloudfront_logs_retention_days = 30
cloudfront_5xx_threshold       = 5
cloudfront_4xx_threshold       = 20
# alerts_email                 = "devops@example.com"  # opcional: confirmar suscripción desde el inbox

github_org                  = "paolovf123"
github_frontend_repo        = "online-store-frontend"
# PRIMER entorno aplicado en esta cuenta AWS → crea el OIDC provider (único por cuenta).
# En production dejar en false (default), que lo referencia vía data source.
create_github_oidc_provider = true
#
# Crear en SSM antes de terraform apply:
# aws ssm put-parameter --name "/online-store/staging/backend-url" --value "https://api-online-store-staging.azurewebsites.net" --type "String"
