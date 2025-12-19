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
    vpc-cni    = { most_recent = true }
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
  }

  eks_managed_node_groups = {
    app = {
      # Stable logical name – avoids timestamped nodegroups
      name = "app"

      min_size     = 1
      desired_size = 2
      max_size     = 3

      capacity_type  = "ON_DEMAND"
      instance_types = ["t3.small"]

      ami_type = "AL2023_x86_64_STANDARD"

      update_config = {
        max_unavailable_percentage = 33
      }

      subnet_ids = module.vpc.private_subnets

      tags = {
        Name        = "${var.cluster_name}-app-ng"
        Environment = var.environment
        Project     = "hartree-eks"
      }
    }
  }

  tags = {
    Environment = var.environment
    Project     = "hartree-eks"
    ManagedBy   = "terraform"
  }

  depends_on = [module.vpc]
}

# ---------------------------------------------------------
# Ensure all security groups are destroy-safe
# ---------------------------------------------------------
resource "aws_security_group_rule" "allow_nodes_from_cluster" {
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = module.eks.cluster_security_group_id
  protocol                 = "-1"
  from_port                = 0
  to_port                  = 0
  type                     = "ingress"

  lifecycle {
    create_before_destroy = true
    ignore_changes        = all
  }
}

resource "aws_security_group_rule" "allow_cluster_from_nodes" {
  security_group_id        = module.eks.cluster_security_group_id
  source_security_group_id = module.eks.node_security_group_id
  protocol                 = "-1"
  from_port                = 0
  to_port                  = 0
  type                     = "ingress"

  lifecycle {
    create_before_destroy = true
    ignore_changes        = all
  }
}
