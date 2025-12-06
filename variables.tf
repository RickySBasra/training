variable "region" {
  type        = string
  default     = "eu-west-2"
  description = "AWS region."
}

variable "environment" {
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  type        = string
  default     = "hartree-eks-dev"
}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
}


