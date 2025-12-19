🧰 EKS / ArgoCD / ALB Controller / Terraform – Debug Commands Cheat Sheet

A compact reference you can paste directly into your repo’s README.

## 🔧 Kubernetes Basics
Get pods, deployments, services, ingresses
kubectl get pods -A
kubectl get deploy -A
kubectl get svc -A
kubectl get ingress -A

Describe resources
kubectl describe pod <pod> -n <ns>
kubectl describe ingress <name> -n <ns>

Show namespace resources
kubectl get all -n <namespace>

## 📦 ArgoCD Debugging
List Argo Applications
kubectl get applications -n argocd

View full application YAML
kubectl -n argocd get application <app> -o yaml

Force ArgoCD to resync
kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite

Check repo-server logs (Git sync issues)
kubectl logs deploy/argocd-repo-server -n argocd

Check if ArgoCD actually downloaded the repo
kubectl -n argocd exec deploy/argocd-repo-server -- find /tmp -maxdepth 4 -type d | grep <app>

## 🌐 ALB Controller Debugging
Check ALB controller logs
kubectl -n kube-system logs deploy/aws-load-balancer-controller -f

Restart ALB controller deployment
kubectl -n kube-system rollout restart deployment aws-load-balancer-controller

Verify ingress picked up by ALB
kubectl get ingress -A

List AWS ENIs created by ALB
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=<vpc-id>" \
  --query 'NetworkInterfaces[*].{ID:NetworkInterfaceId,Desc:Description,Status:Status}'

## ☁️ AWS VPC Debugging
List VPC dependencies
aws ec2 describe-vpcs --vpc-ids <vpc-id>

List route tables
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=<vpc-id>"

List subnets
aws ec2 describe-subnets --filters "Name=vpc-id,Values=<vpc-id>"

List NACLs
aws ec2 describe-network-acls --filters "Name=vpc-id,Values=<vpc-id>"

## 🔐 Security Group Debugging
List rules inside SG
aws ec2 describe-security-groups --group-ids <sg-id>

Find SGs referencing this SG
aws ec2 describe-security-groups \
  --filters Name=ip-permission.group-id,Values=<sg-id>

## 🔧 Terraform Debugging
Show Terraform state resources
terraform state list

Show details for one resource
terraform state show <resource>

Refresh state only
terraform refresh

Force-remove resource from state (use carefully!)
terraform state rm <resource>

## 🧹 Clean Destroy Workflow
1. Delete all ingresses (removes ALBs & ENIs)
kubectl delete ingress -A

2. Confirm ENIs deleted
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=<vpc-id>"

3. Destroy Terraform
terraform destroy -auto-approve

## 📝 ArgoCD Application Manifests Debug
Check revision ArgoCD is pulling
kubectl -n argocd get application <app> -o jsonpath='{.status.sync.revision}'; echo

Check files at that exact commit
git show <revision>:<path>

## 🧩 Node / Autoscaler Debug
Check autoscaler deployment
kubectl get deploy -n kube-system | grep autoscaler

Autoscaler logs
kubectl -n kube-system logs deploy/cluster-autoscaler-aws-cluster-autoscaler





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

kubectl get applications -n argocd
kubectl logs deploy/argocd-repo-server -n argocd
kubectl -n argocd get application guestbook -o yaml 

kubectl -n kube-system rollout restart deployment aws-load-balancer-controller

kubectl get ingress -n guestbook
kubectl get pods -n guestbook
kubectl -n kube-system logs deploy/aws-load-balancer-controller -f

ricky@RICKY-LAPTOP:~/git/training/terraform-gitops$ kubectl get application guestbook -n argocd
NAME        SYNC STATUS   HEALTH STATUS
guestbook   Synced        Healthy
ricky@RICKY-LAPTOP:~/git/training/terraform-gitops$ kubectl get hpa -n guestbook
NAME        REFERENCE              TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
guestbook   Deployment/guestbook   cpu: <unknown>/60%   2         5         0          9s

ricky@RICKY-LAPTOP:~/git/training/terraform-gitops$ kubectl -n argocd describe application guestbook | grep -i hpa -n
134:      Message:  the HPA controller was able to get the target's current scale

# Check Cluster Autoscaler is running
kubectl get deploy -n kube-system | grep autoscaler

# force ArgoCD to resync 
kubectl -n argocd annotate application guestbook argocd.argoproj.io/refresh=hard --overwrite

# Logs
kubectl -n kube-system logs deploy/cluster-autoscaler-aws-cluster-autoscaler -f

# Can't delete VPC
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=vpc-071b1f88c67c8c6e9" \
  --query 'NetworkInterfaces[*].{ID:NetworkInterfaceId,Desc:Description,Status:Status}'


# Delete process
kubectl delete ingress -A
then destroy from terraform-gitops
then terraform

This is a complete, enterprise-grade EKS + GitOps + ALB stack.

If you'd like next steps:
✔ automatic deploy and destroy workflow
✔ pre-destroy hook in terraform-gitops to delete resources created by guestbook
✔ script to detect & delete all ALBs safely
Add TLS (ACM certificate + HTTPS ALB)
Add autoscaling (HPA + Cluster Autoscaler) - guestbook did not scale
Deploy a real microservice app
Add OIDC → GitHub login for ArgoCD & Kubernetes
Add ExternalDNS for automatic DNS records
Add WAF / Shield protections



