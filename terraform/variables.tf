variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL of the EKS cluster (from aws eks describe-cluster)"
  type        = string
}

variable "db_password" {
  description = "RDS master password — store in tfvars or pass via -var, never hardcode"
  type        = string
  sensitive   = true
}

variable "db_subnet_ids" {
  description = "Private subnet IDs for the RDS subnet group"
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC ID where EKS and RDS live"
  type        = string
}

variable "eks_node_security_group_id" {
  description = "Security group ID of EKS worker nodes (to allow RDS ingress)"
  type        = string
}
