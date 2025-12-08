variable "infra_state_bucket" {
  description = "S3 bucket storing infra terraform state"
}

variable "infra_state_key" {
  description = "Key path of infra terraform state"
}

variable "infra_state_bucket_region" {
  description = "Region where the infra state bucket exists"
}

variable "region" {
  description = "Region of the EKS cluster (not necessarily bucket)"
  default     = "eu-west-2"
}
