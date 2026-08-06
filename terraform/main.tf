terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ── IRSA: IAM role for the chatbot pod ────────────────────────────────────────
data "aws_caller_identity" "current" {}

locals {
  oidc_provider = replace(var.cluster_oidc_issuer_url, "https://", "")
}

data "aws_iam_policy_document" "chatbot_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_provider}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:chatbot:chatbot-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "chatbot_irsa" {
  name               = "chatbot-irsa-role"
  assume_role_policy = data.aws_iam_policy_document.chatbot_assume_role.json
}

# Allow the pod to read the two secrets from Secrets Manager
data "aws_iam_policy_document" "chatbot_secrets" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:chatbot/*",
    ]
  }
}

resource "aws_iam_policy" "chatbot_secrets" {
  name   = "chatbot-secrets-policy"
  policy = data.aws_iam_policy_document.chatbot_secrets.json
}

resource "aws_iam_role_policy_attachment" "chatbot_secrets" {
  role       = aws_iam_role.chatbot_irsa.name
  policy_arn = aws_iam_policy.chatbot_secrets.arn
}

# ── RDS PostgreSQL ─────────────────────────────────────────────────────────────
resource "aws_db_subnet_group" "chatbot" {
  name       = "chatbot-db-subnet-group"
  subnet_ids = var.db_subnet_ids
}

resource "aws_security_group" "rds" {
  name        = "chatbot-rds-sg"
  description = "Allow Postgres from EKS nodes only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "chatbot" {
  identifier             = "chatbot-postgres"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  db_name                = "chatbot"
  username               = "chatbot"
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.chatbot.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  skip_final_snapshot    = false
  deletion_protection    = true
  storage_encrypted      = true
  multi_az               = false   # set true for production HA
}

# ── Secrets Manager: store DB URL after RDS is created ────────────────────────
resource "aws_secretsmanager_secret" "db_url" {
  name = "chatbot/db-url"
}

resource "aws_secretsmanager_secret_version" "db_url" {
  secret_id = aws_secretsmanager_secret.db_url.id
  secret_string = "postgresql://chatbot:${var.db_password}@${aws_db_instance.chatbot.endpoint}/chatbot"
}
