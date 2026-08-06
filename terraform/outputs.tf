output "irsa_role_arn" {
  description = "Paste this into k8s/serviceaccount.yaml → eks.amazonaws.com/role-arn"
  value       = aws_iam_role.chatbot_irsa.arn
}

output "rds_endpoint" {
  description = "RDS endpoint (host:port)"
  value       = aws_db_instance.chatbot.endpoint
}
