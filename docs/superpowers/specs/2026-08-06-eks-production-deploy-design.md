# Design: Production Deployment of Chatbot to EKS

**Date:** 2026-08-06
**Status:** Approved

## Goal

Take the existing chatbot-deploy scaffold (currently unversioned, with placeholder
infra values and a couple of app-level correctness bugs) and turn it into a real,
working production deployment on a personal AWS account (934711778945, us-east-1),
version-controlled on GitHub (`Diya0212/chatbot-deploy`, public), with automated
CI/CD via GitHub Actions + ArgoCD.

## Context / Starting State

- App: `langraph_rag_backend.py` (LangGraph chatbot: search, calculator, stock
  price, RAG-over-PDF tools; PostgresSaver checkpointing already implemented,
  contrary to what the stale README claims) + `streamlit_rag_frontend.py`.
- Infra scaffold exists but assumes an EKS cluster already exists (it doesn't),
  and all manifests/Terraform contain placeholder values (account IDs, domains,
  cert ARNs, GitHub org).
- Not yet in git. No GitHub repo. No AWS profile configured for this project.
- Personal AWS profile `chatbot-personal` now configured and verified
  (IAM user `diya02`, account `934711778945`, `AdministratorAccess`, region
  `us-east-1`).
- Tools available locally: `aws`, `gh` (authenticated as Diya0212), `terraform`,
  `kubectl`, `eksctl`, `docker`.

## Issues Found And How They're Addressed

1. **Hardcoded Alpha Vantage API key** in `get_stock_price()` — move to env var
   `ALPHA_VANTAGE_API_KEY`, sourced from Secrets Manager like the other secrets.
2. **In-memory PDF index** (`_THREAD_RETRIEVERS` dict) doesn't survive pod
   restarts/rescheduling — persist the FAISS index to S3, keyed by thread_id;
   in-memory dict becomes a cache, S3 is the durable source of truth.
3. **Placeholder infra values** — filled in from real Terraform outputs once
   provisioned.
4. **No structured logging** — replace prints with Python `logging` at INFO
   level for tool calls, PDF ingestion, and errors.
5. **EKS version placeholder (1.30)** — no longer offered by AWS; pinned to
   **1.36** (current AWS default, standard support through Aug 2027).

## Architecture

```
GitHub (Diya0212/chatbot-deploy, public)
  │  push to main
  ▼
GitHub Actions (OIDC → AWS IAM role, no long-lived keys)
  │  build image → push to ECR
  │  update k8s/deployment.yaml image tag → commit back
  ▼
ArgoCD (running in-cluster, watches k8s/ dir)
  │  auto-sync (prune + self-heal)
  ▼
EKS cluster (v1.36, us-east-1, new VPC, 2x t3.medium managed node group)
  │
  ├─ chatbot Deployment (2 replicas, Streamlit + LangGraph)
  │    - reads secrets via Secrets Store CSI (AWS Secrets Manager)
  │    - IRSA: read/write S3 bucket, read Secrets Manager
  │    - persists chat checkpoints → RDS Postgres
  │    - persists/reads FAISS indexes → S3 (per-thread key)
  │
  ├─ ALB Ingress (internet-facing, sticky sessions for Streamlit WS, HTTP only)
  │
  └─ CloudWatch Container Insights (pod CPU/mem/logs)

RDS Postgres (db.t3.micro, private subnet)  — chat history / LangGraph checkpoints
S3 bucket                                    — serialized FAISS indexes per thread
Secrets Manager                              — groq-api-key, alpha-vantage-key, db-url
ECR repository                               — chatbot container images
```

## App Code Changes (`langraph_rag_backend.py`)

- `get_stock_price`: read `ALPHA_VANTAGE_API_KEY` from `os.environ` instead of
  the hardcoded string; raise/log clearly if missing.
- FAISS persistence:
  - `ingest_pdf`: after building the FAISS index, serialize it
    (`vector_store.save_local(tmp_dir)`) and upload the resulting files to
    `s3://<bucket>/threads/<thread_id>/` using `boto3`. Keep the existing
    in-memory dict as a cache (avoids re-download on every query within the
    same pod/session).
  - `_get_retriever`: on cache miss, attempt to download+load the index from
    S3 before returning `None`. Only fall through to "no document indexed" if
    S3 also has nothing for that thread_id.
  - `_THREAD_METADATA` (filename/chunk counts) also persists to S3 as a small
    JSON sidecar so metadata survives restarts too, not just the index.
- Logging: module-level `logging.getLogger(__name__)`, INFO logs around tool
  invocations (which tool, thread_id), PDF ingestion (filename, chunk count,
  S3 upload), and try/except around S3 and DB calls with logged errors.
  `streamlit_rag_frontend.py` is left as-is except for whatever's needed to not
  break with the backend changes — no logging changes needed there since
  Streamlit already surfaces status inline.
- `requirements.txt`: add `boto3`.

## Terraform Changes (`terraform/`)

New resources added to `main.tf` (or split into new files, e.g. `vpc.tf`,
`eks.tf`, `s3.tf`, `ecr.tf`, `github-oidc.tf` — actual file layout decided
during implementation):

- **VPC**: `terraform-aws-modules/vpc/aws` — 2 AZs, public + private subnets,
  NAT gateway, tagged for EKS auto-discovery
  (`kubernetes.io/cluster/<name>=shared`).
- **EKS cluster**: `terraform-aws-modules/eks/eks` — version `1.36`, private +
  public API endpoint access, cluster name `chatbot`.
- **Managed node group**: 2x `t3.medium`, on-demand, in private subnets.
- **IRSA role** (existing, updated): assume-role condition unchanged; policy
  extended to also allow `s3:GetObject`/`s3:PutObject`/`s3:ListBucket` on the
  new bucket, in addition to existing `secretsmanager:GetSecretValue`.
- **RDS Postgres** (existing, mostly unchanged): `db.t3.micro`, private
  subnets from the new VPC module, security group allowing 5432 from the new
  node group's SG.
- **S3 bucket**: private, versioning optional (skip — not needed for cache
  data), name like `chatbot-faiss-<account_id>` for global uniqueness.
- **ECR repository**: `chatbot`, mutable tags off (immutable, since CI tags
  with git SHA).
- **Secrets Manager**: existing `chatbot/groq-api-key`, `chatbot/db-url`, plus
  new `chatbot/alpha-vantage-key`. DB URL secret version continues to be
  populated from the RDS resource's computed endpoint + password var.
- **GitHub OIDC provider + IAM role**: trust policy scoped to
  `repo:Diya0212/chatbot-deploy:ref:refs/heads/main`, permissions limited to
  ECR push/pull on the `chatbot` repo (not full admin) — this is the role
  `AWS_ROLE_ARN` GitHub secret will reference.
- **CloudWatch Container Insights**: enabled via the `amazon-cloudwatch-observability`
  EKS addon (simplest current path — no separate Fluent Bit DaemonSet to hand-roll).

`variables.tf` / `outputs.tf` updated accordingly — outputs will include
cluster name, cluster endpoint, ECR repo URL, IRSA role ARN, GitHub Actions
role ARN, S3 bucket name — everything needed to fill in k8s manifest
placeholders without guessing.

A `terraform.tfvars` (gitignored) will hold `db_password` and anything else
sensitive; `.gitignore` updated to include it plus `.terraform/`,
`*.tfstate*`.

## K8s Manifest Changes

- `deployment.yaml`: image field left as a placeholder that CI's `yq` step
  overwrites (matches existing pattern) — but initial value set to the real
  ECR URI post-`terraform apply` so first manual deploy works before CI runs
  once. `serviceAccountName` unchanged (already `chatbot-sa`).
- `serviceaccount.yaml`: `eks.amazonaws.com/role-arn` filled in from Terraform
  output.
- `secretproviderclass.yaml`: add third object for
  `chatbot/alpha-vantage-key` → alias `ALPHA_VANTAGE_API_KEY`, and add it to
  `secretObjects` data list so `envFrom` picks it up. Add an `S3_BUCKET_NAME`
  env var (not a secret — plain env or ConfigMap) so the app knows where to
  read/write FAISS indexes.
- `ingress.yaml`: drop the `certificate-arn` annotation and the `HTTPS`
  listen-port entry (HTTP-only for now); `ssl-redirect` annotation removed;
  `host` rule removed (or left to match ALB's own DNS — Ingress `host` isn't
  needed when there's no custom domain, so the rule matches all hosts).
- `argocd-app.yaml`: `repoURL` updated to
  `https://github.com/Diya0212/chatbot-deploy.git`.

## CI/CD Wiring

- `.github/workflows/deploy.yml`: no structural changes needed — it already
  does OIDC auth, ECR push, and manifest update. `AWS_ROLE_ARN` repo secret
  gets set to the new GitHub OIDC IAM role's ARN (Terraform output).
- Steps to actually stand this up:
  1. `git init`, initial commit.
  2. `gh repo create Diya0212/chatbot-deploy --public --source=. --push`.
  3. `terraform apply` (provisions VPC/EKS/RDS/S3/ECR/OIDC role/IRSA/Secrets Manager/Container Insights).
  4. Fill in k8s manifest placeholders from Terraform outputs; commit + push.
  5. `gh secret set AWS_ROLE_ARN --body <github-oidc-role-arn>`.
  6. `aws ecr get-login-password` + manual first `docker build && push` (so
     there's an image in ECR before ArgoCD's first sync — CI will take over
     on subsequent pushes).
  7. Install ArgoCD in-cluster (`kubectl apply` per README's existing
     instructions) + apply `argocd-app.yaml`.
  8. Verify: pod Running, ALB provisioned, app reachable at ALB DNS name, PDF
     upload survives a manual pod delete (proves S3 persistence works), chat
     history survives a pod delete (proves Postgres checkpointing works).

## Testing / Verification Plan

- No unit test suite exists or is being added in this pass (out of scope —
  flagged as a gap, not silently ignored).
- Verification is functional/manual, via the steps in section 8 above: fresh
  deploy → upload PDF → ask a question that requires RAG → delete the pod →
  confirm the same thread still answers from the PDF without re-upload →
  confirm chat history for that thread is intact.
- CI lint step (`ruff check ... || true`) is left as non-blocking for this
  pass — tightening it is a follow-up, not blocking the deploy.

## Explicitly Out of Scope (follow-ups, not silently dropped)

- Custom domain + ACM certificate / HTTPS.
- Real automated test suite / blocking CI lint.
- Multi-AZ RDS, cluster autoscaling, or any other HA hardening beyond
  `replicas: 2`.
- Rotating the previously-exposed Alpha Vantage key (recommended once this is
  live — the old hardcoded key should be treated as compromised).
