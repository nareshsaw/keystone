output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "backup_bucket" {
  description = "S3 bucket for Postgres WAL archives and base backups."
  value       = aws_s3_bucket.backups.bucket
}

output "karpenter_node_role" {
  description = "IAM role name to reference from the Karpenter EC2NodeClass."
  value       = module.karpenter.node_iam_role_name
}

output "configure_kubectl" {
  description = "Command to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
