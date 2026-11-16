# Production-shaped AWS footprint for Keystone. Not applied by CI (validated only), so it costs nothing.

data "aws_caller_identity" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
  tags = {
    Project   = var.name
    ManagedBy = "terraform"
  }
}

# ------------------------------------------------------------------ network
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 48)]
  intra_subnets   = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 52)]

  enable_nat_gateway = true
  single_nat_gateway = true # one NAT keeps dev cost down; use one per AZ in production

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1, "karpenter.sh/discovery" = var.name }
}

# ------------------------------------------------------------------ EKS
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  enable_cluster_creator_admin_permissions = true
  endpoint_public_access                   = true

  addons = {
    coredns                = {}
    eks-pod-identity-agent = { before_compute = true }
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
    aws-ebs-csi-driver     = {}
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  # Small, stable node group for platform controllers; Karpenter provisions everything else.
  eks_managed_node_groups = {
    platform = {
      ami_type       = "BOTTLEROCKET_x86_64"
      instance_types = ["m6i.large"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
      labels         = { "karpenter.sh/controller" = "true" }
    }
  }

  node_security_group_tags = { "karpenter.sh/discovery" = var.name }
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.29.0"

  cluster_name                    = module.eks.cluster_name
  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = "${var.name}-karpenter-node"
  create_pod_identity_association = true
}

# ------------------------------------------------------------------ backups (replaces RustFS on AWS)
resource "aws_s3_bucket" "backups" {
  bucket = "${var.name}-pg-backups-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    id     = "expire-old-backups"
    status = "Enabled"
    filter {}
    expiration {
      days = var.backup_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_policy" "backups_tls_only" {
  bucket = aws_s3_bucket.backups.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.backups.arn, "${aws_s3_bucket.backups.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# Each tenant's Postgres pods get S3 access to their own prefix only, via EKS Pod Identity (no static keys).
resource "aws_iam_role" "pg_backup" {
  for_each = var.db_tenants
  name     = "${var.name}-pg-backup-${each.key}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "pg_backup" {
  for_each = var.db_tenants
  name     = "s3-backup-prefix"
  role     = aws_iam_role.pg_backup[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = aws_s3_bucket.backups.arn
        Condition = { StringLike = { "s3:prefix" = ["${each.key}/*"] } }
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.backups.arn}/${each.key}/*"
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "pg_backup" {
  for_each        = var.db_tenants
  cluster_name    = module.eks.cluster_name
  namespace       = each.key
  service_account = each.value
  role_arn        = aws_iam_role.pg_backup[each.key].arn
}
