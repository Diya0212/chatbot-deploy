output "irsa_role_arn" {
  description = "Paste this into k8s/serviceaccount.yaml → eks.amazonaws.com/role-arn"
  value       = aws_iam_role.chatbot_irsa.arn
}

output "rds_endpoint" {
  description = "RDS endpoint (host:port)"
  value       = aws_db_instance.chatbot.endpoint
}

output "s3_bucket_name" {
  description = "S3 bucket for FAISS index persistence — set as S3_BUCKET_NAME env var on the deployment"
  value       = aws_s3_bucket.faiss_indexes.id
}
