module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.31"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  enable_irsa = true

  cluster_addons = {
    vpc-cni = {
      most_recent = true
    }
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    app = {
      min_size     = 1
      max_size     = 3
      desired_size = 1

      instance_types = ["t3.small"]
      capacity_type  = "SPOT"

      ami_type            = "AL2023_x86_64_STANDARD"
      # ami_release_version = "latest"

      subnet_ids = module.vpc.private_subnets

      tags = {
        Name        = "${var.cluster_name}-app-ng"
        Environment = var.environment
      }
    }
  }

  tags = {
    Environment = var.environment
    Project     = "hartree-eks"
  }

  depends_on = [module.vpc]
}

