# Manual Setup Runbook (post `terraform apply`)

Terraform now owns **only the VPC and EKS cluster** (see `terraform/vpc.tf` and
`terraform/eks.tf`). Everything else below — RDS, S3, ECR, IAM roles, secrets,
cluster add-ons, ArgoCD — is created manually with the AWS CLI / `kubectl` /
`helm`, following the exact same resource names and policies that were
originally designed (and reviewed) for Terraform, so nothing drifts.

Run every command from the `chatbot-deploy/` repo root unless noted otherwise.
All AWS CLI commands assume `--profile chatbot-personal --region us-east-1` —
export these once to avoid repeating them:

```bash
export AWS_PROFILE=chatbot-personal
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=934711778945
export CLUSTER_NAME=chatbot
```

> **Zscaler note:** if any AWS CLI call fails with `SSL: CERTIFICATE_VERIFY_FAILED`,
> retry with `AWS_CA_BUNDLE=/Users/diyabansal/Downloads/zscaler-cert.pem` prepended
> to that one command. This only seems to affect certain S3 virtual-hosted-style
> endpoint calls, not the AWS CLI generally — `terraform` itself has never needed it.

---

## 0. Confirm the cluster is up

```bash
terraform -chdir=terraform output
```

Note the values of `cluster_name`, `vpc_id`, `private_subnet_ids`,
`node_security_group_id`, `cluster_oidc_provider_arn`, `cluster_oidc_provider`
— you'll need all of them below.

```bash
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION
kubectl get nodes
```

Expect 2 nodes, `STATUS Ready` (may take a minute or two after the cluster
finishes creating).

---

## 1. Create the RDS Postgres database

```bash
VPC_ID=$(terraform -chdir=terraform output -raw vpc_id)
SUBNET_IDS=$(terraform -chdir=terraform output -json private_subnet_ids | python3 -c "import json,sys; print(' '.join(json.load(sys.stdin)))")
NODE_SG_ID=$(terraform -chdir=terraform output -raw node_security_group_id)

echo "VPC_ID=$VPC_ID"
echo "SUBNET_IDS=$SUBNET_IDS"
echo "NODE_SG_ID=$NODE_SG_ID"
```

### 1a. DB subnet group

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name chatbot-db-subnet-group \
  --db-subnet-group-description "Private subnets for chatbot RDS" \
  --subnet-ids $SUBNET_IDS
```

### 1b. Security group allowing Postgres from EKS nodes only

```bash
RDS_SG_ID=$(aws ec2 create-security-group \
  --group-name chatbot-rds-sg \
  --description "Allow Postgres from EKS nodes only" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)

echo "RDS_SG_ID=$RDS_SG_ID"

aws ec2 authorize-security-group-ingress \
  --group-id "$RDS_SG_ID" \
  --protocol tcp --port 5432 \
  --source-group "$NODE_SG_ID"
```

### 1c. Choose a strong DB password (do not commit this anywhere)

```bash
DB_PASSWORD=$(python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(24)))")
echo "Generated password — copy it somewhere safe, you won't see it printed again after this session: $DB_PASSWORD"
```

### 1d. Create the instance

```bash
aws rds create-db-instance \
  --db-instance-identifier chatbot-postgres \
  --engine postgres \
  --engine-version 16 \
  --db-instance-class db.t3.micro \
  --allocated-storage 20 \
  --db-name chatbot \
  --master-username chatbot \
  --master-user-password "$DB_PASSWORD" \
  --db-subnet-group-name chatbot-db-subnet-group \
  --vpc-security-group-ids "$RDS_SG_ID" \
  --storage-encrypted \
  --deletion-protection \
  --no-multi-az
```

This takes 5-10 minutes to become available. Poll with:

```bash
aws rds wait db-instance-available --db-instance-identifier chatbot-postgres
```

### 1e. Get the endpoint and build the connection string

```bash
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier chatbot-postgres \
  --query 'DBInstances[0].Endpoint.Address' --output text)

DATABASE_URL="postgresql://chatbot:${DB_PASSWORD}@${RDS_ENDPOINT}:5432/chatbot"
echo "DATABASE_URL=$DATABASE_URL"
```

Keep this value — you'll store it in Secrets Manager in step 4.

---

## 2. Create the S3 bucket for FAISS index persistence

```bash
aws s3api create-bucket \
  --bucket chatbot-faiss-${AWS_ACCOUNT_ID} \
  --region $AWS_REGION

aws s3api put-public-access-block \
  --bucket chatbot-faiss-${AWS_ACCOUNT_ID} \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Bucket name to remember: `chatbot-faiss-934711778945` (this is what you'll set
as `S3_BUCKET_NAME` on the Deployment in step 9).

---

## 3. Create the ECR repository

```bash
aws ecr create-repository \
  --repository-name chatbot \
  --image-tag-mutability IMMUTABLE \
  --image-scanning-configuration scanOnPush=true

aws ecr put-lifecycle-policy \
  --repository-name chatbot \
  --lifecycle-policy-text '{
    "rules": [
      {
        "rulePriority": 1,
        "description": "Keep only the last 10 images",
        "selection": { "tagStatus": "any", "countType": "imageCountMoreThan", "countNumber": 10 },
        "action": { "type": "expire" }
      }
    ]
  }'

ECR_REPO_URL=$(aws ecr describe-repositories --repository-names chatbot --query 'repositories[0].repositoryUri' --output text)
echo "ECR_REPO_URL=$ECR_REPO_URL"
```

---

## 4. Create the Secrets Manager secrets

```bash
aws secretsmanager create-secret --name chatbot/db-url --secret-string "$DATABASE_URL"

aws secretsmanager create-secret --name chatbot/groq-api-key --secret-string "PASTE_YOUR_GROQ_KEY"

aws secretsmanager create-secret --name chatbot/alpha-vantage-key --secret-string "PASTE_YOUR_ALPHA_VANTAGE_KEY"
```

Get a Groq key at https://console.groq.com/keys and an Alpha Vantage key at
https://www.alphavantage.co/support/#api-key (the old hardcoded key found in
this codebase should be treated as compromised — use a fresh one).

---

## 5. Create the IRSA role for the chatbot app pod

This role lets the pod read the three secrets above and read/write the S3
FAISS bucket, via IAM Roles for Service Accounts (IRSA) — the pod assumes
this role through the EKS cluster's OIDC provider.

```bash
OIDC_PROVIDER_ARN=$(terraform -chdir=terraform output -raw cluster_oidc_provider_arn)
OIDC_PROVIDER=$(terraform -chdir=terraform output -raw cluster_oidc_provider)

cat > /tmp/chatbot-irsa-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${OIDC_PROVIDER_ARN}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:chatbot:chatbot-sa",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

IRSA_ROLE_ARN=$(aws iam create-role \
  --role-name chatbot-irsa-role \
  --assume-role-policy-document file:///tmp/chatbot-irsa-trust.json \
  --query 'Role.Arn' --output text)

echo "IRSA_ROLE_ARN=$IRSA_ROLE_ARN"
```

### 5a. Secrets Manager read policy

```bash
cat > /tmp/chatbot-secrets-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
      "Resource": "arn:aws:secretsmanager:${AWS_REGION}:${AWS_ACCOUNT_ID}:secret:chatbot/*"
    }
  ]
}
EOF

SECRETS_POLICY_ARN=$(aws iam create-policy \
  --policy-name chatbot-secrets-policy \
  --policy-document file:///tmp/chatbot-secrets-policy.json \
  --query 'Policy.Arn' --output text)

aws iam attach-role-policy --role-name chatbot-irsa-role --policy-arn "$SECRETS_POLICY_ARN"
```

### 5b. S3 read/write policy

```bash
cat > /tmp/chatbot-s3-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::chatbot-faiss-${AWS_ACCOUNT_ID}",
        "arn:aws:s3:::chatbot-faiss-${AWS_ACCOUNT_ID}/*"
      ]
    }
  ]
}
EOF

S3_POLICY_ARN=$(aws iam create-policy \
  --policy-name chatbot-s3-policy \
  --policy-document file:///tmp/chatbot-s3-policy.json \
  --query 'Policy.Arn' --output text)

aws iam attach-role-policy --role-name chatbot-irsa-role --policy-arn "$S3_POLICY_ARN"
```

---

## 6. Create the AWS Load Balancer Controller IAM role (IRSA)

The Ingress in `k8s/ingress.yaml` needs the AWS Load Balancer Controller
running in-cluster to actually provision an ALB. It needs its own IAM role.

```bash
cat > /tmp/alb-controller-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${OIDC_PROVIDER_ARN}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

ALB_ROLE_ARN=$(aws iam create-role \
  --role-name chatbot-alb-controller-role \
  --assume-role-policy-document file:///tmp/alb-controller-trust.json \
  --query 'Role.Arn' --output text)

echo "ALB_ROLE_ARN=$ALB_ROLE_ARN"
```

Download the official policy (do not hand-write this — it's large and
security-sensitive) and attach it:

```bash
curl -s -o /tmp/alb-controller-iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

ALB_POLICY_ARN=$(aws iam create-policy \
  --policy-name chatbot-alb-controller-policy \
  --policy-document file:///tmp/alb-controller-iam-policy.json \
  --query 'Policy.Arn' --output text)

aws iam attach-role-policy --role-name chatbot-alb-controller-role --policy-arn "$ALB_POLICY_ARN"
```

---

## 7. Create the CloudWatch Container Insights IAM role (Pod Identity)

The `amazon-cloudwatch-observability` EKS addon is already installed (it's
in `terraform/eks.tf`'s `addons` block), but it needs an IAM role via **Pod
Identity** (not IRSA) to actually ship metrics/logs to CloudWatch.

```bash
cat > /tmp/cloudwatch-observability-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "pods.eks.amazonaws.com" },
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }
  ]
}
EOF

CW_ROLE_ARN=$(aws iam create-role \
  --role-name chatbot-cloudwatch-observability-role \
  --assume-role-policy-document file:///tmp/cloudwatch-observability-trust.json \
  --query 'Role.Arn' --output text)

aws iam attach-role-policy \
  --role-name chatbot-cloudwatch-observability-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy

echo "CW_ROLE_ARN=$CW_ROLE_ARN"
```

Confirmed on this cluster: both the `cloudwatch-agent` and `fluent-bit`
DaemonSet pods run as ServiceAccount **`cloudwatch-agent`** in namespace
**`amazon-cloudwatch`** (verified via `kubectl get pods -n amazon-cloudwatch
-o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.serviceAccountName}{"\n"}{end}'`
right after the cluster came up). Create the Pod Identity association:

```bash
aws eks create-pod-identity-association \
  --cluster-name $CLUSTER_NAME \
  --namespace amazon-cloudwatch \
  --service-account cloudwatch-agent \
  --role-arn "$CW_ROLE_ARN"

kubectl delete pods -n amazon-cloudwatch -l app.kubernetes.io/name=cloudwatch-agent
kubectl delete pods -n amazon-cloudwatch -l k8s-app=fluent-bit
```

(Both label selectors are needed — `cloudwatch-agent` and `fluent-bit` are
separate DaemonSets under different labels, but both run as the
`cloudwatch-agent` ServiceAccount and both need to restart to pick up the
new Pod Identity association.)

---

## 8. Create the GitHub Actions OIDC role (for CI → ECR push)

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list $(echo | openssl s_client -servername token.actions.githubusercontent.com -showcerts -connect token.actions.githubusercontent.com:443 2>/dev/null | openssl x509 -fingerprint -sha1 -noout | sed 's/.*=//;s/://g')
```

If a provider for `token.actions.githubusercontent.com` already exists in
this account, `create-open-id-connect-provider` will fail with
`EntityAlreadyExists` — in that case just note the existing provider's ARN
via `aws iam list-open-id-connect-providers` and skip to the next block.

```bash
GITHUB_OIDC_ARN=$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')].Arn" --output text)
echo "GITHUB_OIDC_ARN=$GITHUB_OIDC_ARN"

cat > /tmp/github-actions-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${GITHUB_OIDC_ARN}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
        "StringLike": { "token.actions.githubusercontent.com:sub": "repo:Diya0212/chatbot-deploy:ref:refs/heads/main" }
      }
    }
  ]
}
EOF

GITHUB_ROLE_ARN=$(aws iam create-role \
  --role-name chatbot-github-actions-role \
  --assume-role-policy-document file:///tmp/github-actions-trust.json \
  --query 'Role.Arn' --output text)

echo "GITHUB_ROLE_ARN=$GITHUB_ROLE_ARN"
```

**Double-check** the `sub` condition above reads exactly
`repo:Diya0212/chatbot-deploy:ref:refs/heads/main` — this is what restricts
the role to CI runs on this repo's `main` branch only, nothing else.

```bash
ECR_REPO_ARN=$(aws ecr describe-repositories --repository-names chatbot --query 'repositories[0].repositoryArn' --output text)

cat > /tmp/github-actions-ecr-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:BatchCheckLayerAvailability",
        "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload"
      ],
      "Resource": "${ECR_REPO_ARN}"
    },
    {
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    }
  ]
}
EOF

GITHUB_ECR_POLICY_ARN=$(aws iam create-policy \
  --policy-name chatbot-github-actions-ecr-policy \
  --policy-document file:///tmp/github-actions-ecr-policy.json \
  --query 'Policy.Arn' --output text)

aws iam attach-role-policy --role-name chatbot-github-actions-role --policy-arn "$GITHUB_ECR_POLICY_ARN"
```

### 8a. Set the GitHub repo secret

```bash
gh secret set AWS_ROLE_ARN --repo Diya0212/chatbot-deploy --body "$GITHUB_ROLE_ARN"
gh secret list --repo Diya0212/chatbot-deploy
```

---

## 9. Fill in the k8s manifest placeholders

Edit these files with the real values gathered above:

- **`k8s/serviceaccount.yaml`** — set `eks.amazonaws.com/role-arn` to `$IRSA_ROLE_ARN`
- **`k8s/deployment.yaml`** — set `image` to `${ECR_REPO_URL}:latest`; add an
  env var `S3_BUCKET_NAME: chatbot-faiss-934711778945` alongside the existing
  `envFrom`
- **`k8s/secretproviderclass.yaml`** — add a third object for
  `chatbot/alpha-vantage-key` → alias `ALPHA_VANTAGE_API_KEY`, and add it to
  `secretObjects` so `envFrom` picks it up (mirror the existing two entries)
- **`k8s/ingress.yaml`** — drop the `HTTPS` listen port, `ssl-redirect`, and
  `certificate-arn` annotations, and the `host` rule (HTTP-only via the ALB's
  own DNS name for now — no domain/cert yet)
- **`k8s/argocd-app.yaml`** — set `repoURL` to
  `https://github.com/Diya0212/chatbot-deploy.git`

Commit and push these changes once filled in.

---

## 10. Build and push the first image

```bash
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

docker build -t chatbot:latest .
docker tag chatbot:latest ${ECR_REPO_URL}:latest
docker push ${ECR_REPO_URL}:latest
```

---

## 11. Install cluster add-ons

```bash
# Secrets Store CSI Driver + AWS provider
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm repo add aws-secrets-manager https://aws.github.io/secrets-store-csi-driver-provider-aws
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  -n kube-system --create-namespace --set syncSecret.enabled=true

helm install secrets-provider-aws aws-secrets-manager/secrets-store-csi-driver-provider-aws -n kube-system

# AWS Load Balancer Controller — service account created manually, annotated with the IRSA role
kubectl create serviceaccount aws-load-balancer-controller -n kube-system --dry-run=client -o yaml | \
  kubectl annotate --local -f - eks.amazonaws.com/role-arn="$ALB_ROLE_ARN" -o yaml | \
  kubectl apply -f -

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

Wait for that last pod to show `Running` before continuing.

---

## 12. Apply the app manifests

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/serviceaccount.yaml
kubectl apply -f k8s/secretproviderclass.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml
```

---

## 13. Install ArgoCD and hand off future deploys to it

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available --timeout=180s deployment/argocd-server -n argocd

kubectl apply -f k8s/argocd-app.yaml -n argocd
```

From this point on, every `git push` to `main` (after CI builds and pushes a
new image, and updates `k8s/deployment.yaml`'s image tag) gets auto-synced by
ArgoCD.

---

## 14. Verify everything works

```bash
# Pods running
kubectl get pods -n chatbot -w
# (Ctrl-C once both show Running / 1/1)

# Secrets actually synced
kubectl get secret chatbot-app-secrets -n chatbot -o jsonpath='{.data}' | python3 -m json.tool

# ALB DNS name (may take 2-3 min to appear after ingress creation)
kubectl get ingress chatbot-ingress -n chatbot -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Health check
curl -sS -o /dev/null -w "%{http_code}\n" http://<alb-hostname>/_stcore/health   # expect 200
```

Then in a browser at `http://<alb-hostname>`: upload a PDF, ask a
PDF-specific question, note the thread ID, run
`kubectl delete pod -n chatbot -l app=chatbot`, wait for pods to come back
`Running`, reload, select the same thread, and ask again **without
re-uploading** — this proves S3 persistence and Postgres checkpointing both
survived the pod restart.
