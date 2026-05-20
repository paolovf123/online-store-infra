output "cloudfront_url" {
  description = "URL pública de la aplicación"
  value       = "https://${aws_cloudfront_distribution.frontend.domain_name}"
}

output "cloudfront_distribution_id" {
  description = "ID de la distribución CloudFront (útil para invalidaciones manuales)"
  value       = aws_cloudfront_distribution.frontend.id
}

output "s3_frontend_bucket" {
  description = "Nombre del bucket S3 que sirve el frontend"
  value       = aws_s3_bucket.frontend.id
}

output "github_actions_role_arn" {
  description = "ARN del rol IAM que el workflow de GitHub Actions del repo frontend debe asumir vía OIDC. Setear como secret AWS_DEPLOY_ROLE_ARN en GitHub."
  value       = aws_iam_role.github_actions_deploy.arn
}

output "alerts_topic_arn" {
  description = "ARN del topic SNS para alarmas de CloudFront"
  value       = aws_sns_topic.alerts.arn
}

output "cloudfront_logs_bucket" {
  description = "Bucket S3 con los access logs de CloudFront"
  value       = aws_s3_bucket.cloudfront_logs.id
}

output "cloudwatch_dashboard_url" {
  description = "URL del dashboard de CloudWatch con métricas de CloudFront"
  value       = "https://console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}
