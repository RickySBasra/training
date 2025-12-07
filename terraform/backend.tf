terraform {
  backend "s3" {
    bucket         = "hartree-tfstate"
    key            = "eks/dev/terraform.tfstate"
    region         = "eu-west-2"
    dynamodb_table = "hartree-tfstate-locks"
    encrypt        = true
  }
}

