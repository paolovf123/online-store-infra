variable "project_name" {
  description = "Nombre del proyecto (kebab-case). Base del naming de recursos."
  type        = string
  default     = "online-store"
}

variable "environment" {
  description = "Entorno de despliegue: staging o production."
  type        = string
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "Debe ser 'staging' o 'production'."
  }
}

variable "aws_region" {
  description = "Región de AWS donde se crean los recursos."
  type        = string
  default     = "us-east-1"
}

variable "resource_suffix" {
  description = "Sufijo corto único para evitar colisiones de nombres globales en S3 (e.g. abc1)."
  type        = string
}

variable "github_org" {
  description = "Organización o usuario de GitHub propietario del repo frontend (e.g. paolovf123)."
  type        = string
}

variable "github_frontend_repo" {
  description = "Nombre del repo del frontend (sin owner) — el OIDC role trust se restringe a este repo."
  type        = string
}

variable "github_branch" {
  description = "Rama del repo frontend asociada a este entorno (develop para staging, main para production). Informativo: el gate de rama lo aplican el trigger del workflow y la branch policy del GitHub Environment; el trust del rol IAM se restringe por environment, no por rama."
  type        = string
}

variable "create_github_oidc_provider" {
  description = "Si true, crea el OIDC provider de GitHub Actions. Solo se puede tener UNO por cuenta AWS: setear true en el primer entorno aplicado y false en los demás (que lo referencian via data source)."
  type        = bool
  default     = false
}

variable "cloudfront_price_class" {
  description = "Clase de precio de CloudFront. PriceClass_100 = US/EU/Asia (más barato)."
  type        = string
  default     = "PriceClass_100"
}

variable "cloudfront_logs_retention_days" {
  description = "Días que se conservan los logs de acceso de CloudFront antes de eliminarse."
  type        = number
  default     = 30
}

variable "alerts_email" {
  description = "Email para recibir notificaciones de alarmas CloudFront. Vacío = sin suscripción."
  type        = string
  default     = ""
}

variable "cloudfront_5xx_threshold" {
  description = "Umbral (%) de la tasa de errores 5xx en CloudFront para disparar la alarma."
  type        = number
  default     = 1
}

variable "cloudfront_4xx_threshold" {
  description = "Umbral (%) de la tasa de errores 4xx en CloudFront (alarma informativa)."
  type        = number
  default     = 10
}

variable "enable_no_traffic_alarm" {
  description = "Si true, crea una alarma que dispara cuando CloudFront no recibe tráfico (recomendado solo en producción)."
  type        = bool
  default     = false
}
