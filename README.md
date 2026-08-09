# chatbot-deploy

Deployment files for the Multi-Utility RAG Chatbot on EKS.

For running the app as a standalone Docker container (no Kubernetes required), see [DOCKER_DEPLOY.md](DOCKER_DEPLOY.md).

## Directory layout

```
chatbot-deploy/
  Dockerfile                      # multi-stage build (bakes in HuggingFace model)
  requirements.txt                # Python deps for the container
  .dockerignore
  .github/workflows/deploy.yml    # CI: build → push ECR → update manifest → ArgoCD syncs
  k8s/
    namespace.yaml                # chatbot namespace
    serviceaccount.yaml           # IRSA ServiceAccount (pod identity for Secrets Manager)
    secretproviderclass.yaml      # Secrets Store CSI — pulls secrets from AWS Secrets Manager
    deployment.yaml               # 2-replica Deployment (safe with Postgres)
    service.yaml                  # ClusterIP service
    ingress.yaml                  # ALB Ingress with sticky sessions for Streamlit
    argocd-app.yaml               # ArgoCD Application
  terraform/
    main.tf                       # IRSA role + RDS Postgres + Secrets Manager secrets
    variables.tf
    outputs.tf
```

## Pre-requisites on your EKS cluster

```bash
# 1. AWS Load Balancer Controller
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=<your-cluster>

# 2. EBS CSI Driver (for any future PVC needs)
eksctl create addon --name aws-ebs-csi-driver --cluster <your-cluster>

# 3. Secrets Store CSI Driver + AWS Provider
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  -n kube-system --set syncSecret.enabled=true

helm repo add aws-secrets-manager https://aws.github.io/secrets-store-csi-driver-provider-aws
helm install secrets-provider-aws aws-secrets-manager/secrets-store-csi-driver-provider-aws \
  -n kube-system

# 4. ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

## Terraform: provision IRSA role + RDS + Secrets Manager

```bash
cd terraform

# Create a tfvars file (never commit this)
cat > terraform.tfvars <<EOF
cluster_name                = "your-cluster-name"
cluster_oidc_issuer_url     = "https://oidc.eks.us-east-1.amazonaws.com/id/XXXX"
db_password                 = "your-strong-password"
db_subnet_ids               = ["subnet-aaa", "subnet-bbb"]
vpc_id                      = "vpc-xxxx"
eks_node_security_group_id  = "sg-xxxx"
EOF

terraform init
terraform apply

# Copy the IRSA role ARN from outputs into k8s/serviceaccount.yaml
terraform output irsa_role_arn
```

Create the Groq API key secret manually (one-time):
```bash
aws secretsmanager create-secret \
  --name chatbot/groq-api-key \
  --secret-string "your-groq-api-key"
```

## Build & push image to ECR

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com

docker build -t chatbot:latest .
docker tag chatbot:latest <account-id>.dkr.ecr.us-east-1.amazonaws.com/chatbot:latest
docker push <account-id>.dkr.ecr.us-east-1.amazonaws.com/chatbot:latest
```

## Deploy via ArgoCD

1. Update `k8s/serviceaccount.yaml` with the Terraform-output IRSA role ARN
2. Update `k8s/deployment.yaml` image with your ECR URI
3. Update `k8s/ingress.yaml` host and ACM certificate ARN
4. Update `k8s/argocd-app.yaml` with your GitHub repo URL
5. Push this repo to GitHub
6. `kubectl apply -f k8s/argocd-app.yaml -n argocd`

ArgoCD will sync on every `git push` automatically.

## CI/CD flow (GitHub Actions)

```
git push → GitHub Actions:
  1. Lint
  2. Build Docker image
  3. Push to ECR (tagged with git SHA)
  4. Update image tag in k8s/deployment.yaml
  5. Commit & push manifest back to repo
  → ArgoCD detects change → syncs cluster
```

Add `AWS_ROLE_ARN` to GitHub Secrets (the CI role, not the IRSA role).

## Backend change needed: SQLite → PostgreSQL

The app code (`langraph_rag_backend.py`) currently uses `SqliteSaver`.
Before deploying, swap it to `PostgresSaver`:

```python
# Install: uv add langgraph-checkpoint-postgres psycopg[binary]

import os
from psycopg_pool import ConnectionPool
from langgraph.checkpoint.postgres import PostgresSaver

pool = ConnectionPool(conninfo=os.environ["DATABASE_URL"])
checkpointer = PostgresSaver(pool)
checkpointer.setup()   # creates checkpoint tables on first run
```

Then remove the `sqlite3` import and `SqliteSaver` lines.

## Notes

- **replicas: 2** is safe because persistence is on RDS Postgres (not a local file)
- Sticky sessions on ALB are still required for Streamlit WebSocket
- `terraform.tfvars` and `.env` must never be committed — add both to `.gitignore`
