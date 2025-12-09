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

Add TLS (ACM certificate + HTTPS ALB)

Add autoscaling (HPA + Cluster Autoscaler)

Deploy a real microservice app

Add OIDC → GitHub login for ArgoCD & Kubernetes

Add ExternalDNS for automatic DNS records

Add WAF / Shield protections