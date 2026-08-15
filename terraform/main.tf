terraform {
  required_version = ">= 1.5.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.52"
    }
  }

  backend "s3" {
    bucket       = "chatbot-terraform-state-934711778945"
    key          = "chatbot/terraform.tfstate"
    region       = "us-east-1"
    profile      = "chatbot-personal"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region  = var.aws_region
  profile = "chatbot-personal"
}
