variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "db_password" {
  description = "RDS master password — store in tfvars or pass via -var, never hardcode"
  type        = string
  sensitive   = true
}
