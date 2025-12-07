# training
Personal Repo for training


aws dynamodb create-table \
  --table-name hartree-tfstate-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

aws dynamodb describe-table --table-name hartree-tfstate-locks

terraform init
terraform plan
terraform apply -auto-approve
terraform destroy -auto-approve

