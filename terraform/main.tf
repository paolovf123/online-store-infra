locals {
  common_tags = {
    project     = var.project_name
    environment = var.environment
    managed_by  = "terraform"
  }
}

# ─── S3: bucket del frontend (privado, acceso solo desde CloudFront) ──────────

resource "aws_s3_bucket" "frontend" {
  bucket = "${var.project_name}-frontend-${var.environment}-${var.resource_suffix}"
  tags   = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Limpieza de versiones antiguas: las versiones obsoletas se eliminan tras 30 días
resource "aws_s3_bucket_lifecycle_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 30 }
  }
}

# ─── S3: bucket para logs de acceso de CloudFront ─────────────────────────────

resource "aws_s3_bucket" "cloudfront_logs" {
  bucket        = "${var.project_name}-cf-logs-${var.environment}-${var.resource_suffix}"
  force_destroy = true
  tags          = local.common_tags
}

resource "aws_s3_bucket_ownership_controls" "cloudfront_logs" {
  bucket = aws_s3_bucket.cloudfront_logs.id
  rule { object_ownership = "BucketOwnerPreferred" }
}

resource "aws_s3_bucket_public_access_block" "cloudfront_logs" {
  bucket                  = aws_s3_bucket.cloudfront_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudfront_logs" {
  bucket = aws_s3_bucket.cloudfront_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudfront_logs" {
  bucket = aws_s3_bucket.cloudfront_logs.id
  rule {
    id     = "expire-logs"
    status = "Enabled"
    filter {}
    expiration { days = var.cloudfront_logs_retention_days }
  }
}

# ─── CloudFront ───────────────────────────────────────────────────────────────

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.project_name}-oac-${var.environment}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_distribution" "frontend" {
  # CloudFront (logging legacy) valida que el bucket de logs tenga ACLs habilitadas.
  # Forzamos el orden para evitar la carrera con ownership_controls (que recién propaga
  # el BucketOwnerPreferred): sin esto, CreateDistribution falla de forma intermitente.
  depends_on = [aws_s3_bucket_ownership_controls.cloudfront_logs]

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = var.cloudfront_price_class
  comment             = "${var.project_name}-${var.environment}"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.frontend.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    target_origin_id       = "S3-${aws_s3_bucket.frontend.id}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # Cache-Control viene del origen: index.html no-cache, assets immutable max-age=1y
    # (definido en el step de deploy del workflow de GitHub Actions)
    cache_policy_id = data.aws_cloudfront_cache_policy.caching_optimized.id
  }

  logging_config {
    bucket          = aws_s3_bucket.cloudfront_logs.bucket_domain_name
    prefix          = "${var.environment}/"
    include_cookies = false
  }

  # Angular SPA routing: redirigir 403/404 al index.html
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = local.common_tags
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn }
      }
    }]
  })
}

# ─── IAM: GitHub Actions OIDC ─────────────────────────────────────────────────
# El OIDC provider es global por cuenta AWS (no por entorno). En el primer entorno
# que aplica setear create_github_oidc_provider=true; en los siguientes, false (se
# referencia via data source).

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = local.common_tags
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# Rol asumido por el workflow de GitHub Actions del repo frontend para deployar
# este entorno. La condición sub limita a un repo y un GitHub Environment
# específicos: cuando el job declara `environment:`, el claim `sub` del token OIDC
# toma la forma repo:<org>/<repo>:environment:<env> (NO la forma :ref:refs/heads/).
resource "aws_iam_role" "github_actions_deploy" {
  name = "${var.project_name}-gh-actions-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_frontend_repo}:environment:${var.environment}"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "github_actions_deploy" {
  name = "deploy-policy"
  role = aws_iam_role.github_actions_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject", "s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.frontend.arn, "${aws_s3_bucket.frontend.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = "arn:aws:cloudfront::*:distribution/${aws_cloudfront_distribution.frontend.id}"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/${var.environment}/*"
      }
    ]
  })
}

# ─── SNS: notificaciones de alarmas ───────────────────────────────────────────

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts-${var.environment}"
  tags = local.common_tags
}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid    = "AllowCloudWatchAlarms"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alerts_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alerts_email
}

# ─── CloudWatch alarms: salud de CloudFront ───────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "cloudfront_5xx" {
  alarm_name          = "${var.project_name}-cf-5xx-${var.environment}"
  alarm_description   = "Tasa de errores 5xx en CloudFront > ${var.cloudfront_5xx_threshold}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "5xxErrorRate"
  namespace           = "AWS/CloudFront"
  period              = 300
  statistic           = "Average"
  threshold           = var.cloudfront_5xx_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    DistributionId = aws_cloudfront_distribution.frontend.id
    Region         = "Global"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
  tags          = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "cloudfront_4xx" {
  alarm_name          = "${var.project_name}-cf-4xx-${var.environment}"
  alarm_description   = "Tasa de errores 4xx en CloudFront > ${var.cloudfront_4xx_threshold}% (informativa)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "4xxErrorRate"
  namespace           = "AWS/CloudFront"
  period              = 300
  statistic           = "Average"
  threshold           = var.cloudfront_4xx_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    DistributionId = aws_cloudfront_distribution.frontend.id
    Region         = "Global"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  tags          = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "cloudfront_no_traffic" {
  count               = var.enable_no_traffic_alarm ? 1 : 0
  alarm_name          = "${var.project_name}-cf-no-traffic-${var.environment}"
  alarm_description   = "CloudFront no recibe tráfico (posible outage o desvío de DNS)"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "Requests"
  namespace           = "AWS/CloudFront"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "breaching"

  dimensions = {
    DistributionId = aws_cloudfront_distribution.frontend.id
    Region         = "Global"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  tags          = local.common_tags
}

# ─── CloudWatch Dashboard ─────────────────────────────────────────────────────

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "CloudFront — Requests"
          region = "us-east-1"
          stat   = "Sum"
          period = 300
          view   = "timeSeries"
          metrics = [
            ["AWS/CloudFront", "Requests", "DistributionId", aws_cloudfront_distribution.frontend.id, "Region", "Global"]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "CloudFront — Error rate (%)"
          region = "us-east-1"
          stat   = "Average"
          period = 300
          view   = "timeSeries"
          metrics = [
            ["AWS/CloudFront", "4xxErrorRate", "DistributionId", aws_cloudfront_distribution.frontend.id, "Region", "Global"],
            [".", "5xxErrorRate", ".", ".", ".", "."]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 24
        height = 6
        properties = {
          title  = "CloudFront — Bytes downloaded"
          region = "us-east-1"
          stat   = "Sum"
          period = 300
          view   = "timeSeries"
          metrics = [
            ["AWS/CloudFront", "BytesDownloaded", "DistributionId", aws_cloudfront_distribution.frontend.id, "Region", "Global"]
          ]
        }
      },
    ]
  })
}
