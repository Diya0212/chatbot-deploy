# Docker Deployment Guide

Run the chatbot as a standalone Docker container (EC2, local machine, or any Docker host) without EKS/ArgoCD. For the Kubernetes/EKS deployment, see [README.md](README.md).

## Prerequisites

- Docker installed and running
- A [Groq API key](https://console.groq.com/keys)
- (Optional) An [Alpha Vantage API key](https://www.alphavantage.co/support/#api-key) for the stock-price tool

## Required environment variables

| Variable | Required | Purpose |
|---|---|---|
| `DATABASE_URL` | Yes | Postgres connection string used by `PostgresSaver` for LangGraph checkpointing |
| `GROQ_API_KEY` | Yes | Used by `ChatGroq` for the LLM |
| `ALPHA_VANTAGE_API_KEY` | No | Enables the `get_stock_price` tool |
| `S3_BUCKET_NAME` | No | Enables persisting/loading FAISS indexes to/from S3 |

## Instance sizing (if deploying on EC2)

Use at least a **t3.medium** (2 vCPU, 4 GiB RAM) with a **20 GB+ gp3** root volume. The build stage installs `sentence-transformers` + `torch` and downloads an embedding model — smaller instances risk running out of memory or disk during the build.

## 1. Build the image

```bash
git clone https://github.com/Diya0212/chatbot-deploy.git
cd chatbot-deploy
docker build -t chatbot:local .
```

This is a two-stage build:
- **Stage 1** installs `sentence-transformers` and pre-downloads the `all-MiniLM-L6-v2` embedding model into the image, so the container never cold-starts by fetching it from HuggingFace at runtime.
- **Stage 2** installs the app's runtime dependencies and copies in the application code.

Both stages install the **CPU-only PyTorch wheel** explicitly:
```dockerfile
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu
```
The default PyPI `torch` wheel bundles ~2 GB of unused CUDA/GPU packages. Since this app only does CPU inference, skipping them avoids exhausting disk space on smaller instances during the build.

## 2. Start Postgres

The app requires a running Postgres instance for `DATABASE_URL`. For local/EC2 testing, run one as a container on a shared Docker network:

```bash
docker network create chatbot-net

docker run -d --name chatbot-db --network chatbot-net \
  -e POSTGRES_PASSWORD=devpass \
  -e POSTGRES_DB=chatbot \
  postgres:16
```

For production, point `DATABASE_URL` at a real RDS instance instead (see `terraform/main.tf`, which provisions this and stores the connection string in AWS Secrets Manager).

## 3. Run the app

```bash
export GROQ_API_KEY="your-groq-key"
export ALPHA_VANTAGE_API_KEY="your-alpha-vantage-key"   # optional

docker run -d --name chatbot-app --network chatbot-net \
  -p 8501:8501 \
  -e DATABASE_URL="postgresql://postgres:devpass@chatbot-db:5432/chatbot" \
  -e GROQ_API_KEY="$GROQ_API_KEY" \
  -e ALPHA_VANTAGE_API_KEY="$ALPHA_VANTAGE_API_KEY" \
  chatbot:local
```

`chatbot-db` resolves via Docker's built-in DNS since both containers share the `chatbot-net` network — no need for `host.docker.internal` (which isn't available by default on Linux Docker hosts like EC2).

## 4. Verify it's running

```bash
docker logs -f chatbot-app
```

Look for:
```
PostgresSaver checkpointer initialized
```

Then open `http://<host>:8501` in your browser. On EC2, make sure the instance's security group allows inbound TCP `8501` from your IP.

## Troubleshooting

### `No space left on device` during `docker build`
Reclaim space from prior failed builds:
```bash
docker system prune -af --volumes
```
Then rebuild. If this still recurs, grow the root EBS volume — the CUDA-bundled `torch` wheel this Dockerfile avoids is the most common cause.

### `psycopg.errors.ActiveSqlTransaction: CREATE INDEX CONCURRENTLY cannot run inside a transaction block`
`PostgresSaver.setup()` runs `CREATE INDEX CONCURRENTLY`, which Postgres refuses to run inside an implicit transaction. The connection pool must use autocommit:
```python
_pool = ConnectionPool(conninfo=os.environ["DATABASE_URL"], kwargs={"autocommit": True})
```
This is already fixed in `langraph_rag_backend.py` — if you see this error, make sure you're on the latest `main`.

### `groq.APIError: Failed to call a function. Please adjust your prompt.`
Groq's tool-calling API validates all bound tool schemas together on every request — a single malformed schema can cause *every* tool call to fail, not just the tool with the bad schema. A common cause is an `Optional[str] = None` parameter, which Pydantic v2 renders as an `anyOf`/`null` JSON Schema union that Groq doesn't reliably support. Keep tool parameters as plain required types (`str`, not `Optional[str]`) unless the tool genuinely handles a missing value.

If this error appears intermittently with no schema issue, it can also be transient — Groq's streamed tool-call token generation is occasionally flaky for `llama-3.3-70b-versatile`. Retrying the same query often succeeds.

## Cleanup

```bash
docker rm -f chatbot-app chatbot-db
docker network rm chatbot-net
```
