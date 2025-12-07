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

git tag
git tag -l "0.2"
git tag "0.2" -m "Updated to use argocd + cleanup script"
git push --tags

aws eks update-kubeconfig --name hartree-eks-dev --region eu-west-2
kubectl get pods -n argocd

kubectl get nodes
kubectl get ns 

kubectl -n kube-system get configmap aws-auth -o yaml

https://<ARGOCD-LOADBALANCER-DNS> --> kubectl get svc -n argocd argocd-server