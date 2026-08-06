module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "chatbot"
  kubernetes_version = "1.36"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access = true

  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true

  addons = {
    coredns = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
    amazon-cloudwatch-observability = {}
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.medium"]

      min_size     = 2
      max_size     = 2
      desired_size = 2

      subnet_ids = module.vpc.private_subnets
    }
  }

  tags = {
    Project = "chatbot"
  }
}
