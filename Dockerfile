# ── Stage 1: download HuggingFace model so the pod never cold-starts ──────────
FROM python:3.12-slim AS model-cache

# CPU-only torch wheel — the default PyPI wheel bundles ~2GB of unused CUDA/GPU deps
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu
RUN pip install --no-cache-dir sentence-transformers

RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('sentence-transformers/all-MiniLM-L6-v2')"

# ── Stage 2: final image ───────────────────────────────────────────────────────
FROM python:3.12-slim

WORKDIR /app

# System deps for FAISS + PDF loading
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# Copy cached model from stage 1
COPY --from=model-cache /root/.cache/huggingface /root/.cache/huggingface

# Install Python dependencies (CPU-only torch first, same reason as stage 1)
COPY requirements.txt .
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY langraph_rag_backend.py .
COPY streamlit_rag_frontend.py .

EXPOSE 8501

# Streamlit needs these env vars to run headlessly inside a container
ENV STREAMLIT_SERVER_HEADLESS=true \
    STREAMLIT_SERVER_PORT=8501 \
    STREAMLIT_SERVER_ADDRESS=0.0.0.0 \
    STREAMLIT_BROWSER_GATHER_USAGE_STATS=false

CMD ["streamlit", "run", "streamlit_rag_frontend.py"]
