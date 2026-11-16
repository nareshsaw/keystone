variable "name" {
  description = "Name prefix for every resource."
  type        = string
  default     = "keystone"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "ap-south-1"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.34"
}

variable "vpc_cidr" {
  description = "CIDR block of the platform VPC."
  type        = string
  default     = "10.40.0.0/16"
}

variable "backup_retention_days" {
  description = "Days to keep Postgres base backups and WAL archives."
  type        = number
  default     = 30
}

variable "db_tenants" {
  description = "Tenant database clusters allowed to write backups: namespace => cluster name (= its service account)."
  type        = map(string)
  default = {
    orders = "orders-db"
  }
}
