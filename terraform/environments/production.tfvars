environment                    = "production"
aws_region                     = "us-east-1"
resource_suffix                = "prod01"
github_branch                  = "main"
cloudfront_price_class         = "PriceClass_100"
cloudfront_logs_retention_days = 90
cloudfront_5xx_threshold       = 1
cloudfront_4xx_threshold       = 10
enable_no_traffic_alarm        = true
# alerts_email                 = "devops@example.com"  # opcional: confirmar suscripción desde el inbox

# Completar antes de aplicar:
# github_org           = "paolovf123"
# github_frontend_repo = "online-store-frontend"
#
# Si es el PRIMER entorno que aplicas en esta cuenta AWS, setear:
# create_github_oidc_provider = true
# En los siguientes entornos dejar en false (default).
#
# Crear en SSM antes de terraform apply:
# aws ssm put-parameter --name "/online-store/production/backend-url" --value "https://api-online-store.azurewebsites.net" --type "String"
