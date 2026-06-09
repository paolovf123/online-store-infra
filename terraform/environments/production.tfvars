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

github_org           = "paolovf123"
github_frontend_repo = "online-store-frontend"
# create_github_oidc_provider se deja en false (default): el OIDC provider ya
# fue creado por el entorno staging y aquí se referencia vía data source.
# URL del backend (el frontend la hornea en build-time; la lee el deploy desde SSM).
# Placeholder hasta tener el backend real; cambiar aquí + apply (Terraform gestiona el parámetro).
backend_url = "https://placeholder.invalid"
