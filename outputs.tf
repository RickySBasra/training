output "cluster_name" {
  value       = module.eks.cluster_name
  description = "EKS cluster name"
}

output "cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "EKS API endpoint"
}

output "cluster_ca" {
  value       = module.eks.cluster_certificate_authority_data
  description = "EKS cluster CA"
}

output "region" {
  value = var.region
}

output "alb_dns" {
  value = aws_lb.app_alb.dns_name
}

