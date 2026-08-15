output "cluster_name" {
  description = "EKS cluster name — use with `aws eks update-kubeconfig --name <this>`"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_oidc_provider_arn" {
  description = "OIDC provider ARN for the cluster — needed to build IRSA trust policies manually"
  value       = module.eks.oidc_provider_arn
}

output "cluster_oidc_provider" {
  description = "OIDC provider (issuer without scheme) — needed to build IRSA trust policy conditions manually"
  value       = module.eks.oidc_provider
}

output "node_security_group_id" {
  description = "Security group ID of the EKS worker nodes — needed to allow RDS/other ingress manually"
  value       = module.eks.node_security_group_id
}

output "vpc_id" {
  description = "VPC ID — needed for manually creating RDS, security groups, etc."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs — needed for manually creating an RDS subnet group"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnets
}
