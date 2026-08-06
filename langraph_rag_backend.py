from __future__ import annotations

import logging
import os
import tempfile
import json
from typing import Annotated, Any, Dict, Optional, TypedDict

from dotenv import load_dotenv
from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain_community.document_loaders import PyPDFLoader
from langchain_community.tools import DuckDuckGoSearchRun
from langchain_community.vectorstores import FAISS
from langchain_core.messages import BaseMessage, SystemMessage
from langchain_core.tools import tool
from langchain_groq import ChatGroq
from langchain_huggingface import HuggingFaceEmbeddings
from psycopg_pool import ConnectionPool
from langgraph.checkpoint.postgres import PostgresSaver
from langgraph.graph import START, StateGraph
from langgraph.graph.message import add_messages
from langgraph.prebuilt import ToolNode, tools_condition
import requests
import boto3

load_dotenv()

# -------------------
# 1. LLM + embeddings
# -------------------
llm = ChatGroq(model="llama-3.3-70b-versatile")
embeddings = HuggingFaceEmbeddings(model_name="sentence-transformers/all-MiniLM-L6-v2")

# -------------------
# 2. PDF retriever store (per thread)
# -------------------
_THREAD_RETRIEVERS: Dict[str, Any] = {}
_THREAD_METADATA: Dict[str, dict] = {}

logger = logging.getLogger(__name__)

_S3_BUCKET = os.environ.get("S3_BUCKET_NAME")
_s3_client = boto3.client("s3") if _S3_BUCKET else None


def _s3_prefix(thread_id: str) -> str:
    return f"threads/{thread_id}/"


def _upload_index_to_s3(thread_id: str, local_dir: str, metadata: dict) -> None:
    """Upload a saved FAISS index directory and its metadata sidecar to S3."""
    if _s3_client is None:
        return
    prefix = _s3_prefix(thread_id)
    for filename in os.listdir(local_dir):
        _s3_client.upload_file(
            os.path.join(local_dir, filename), _S3_BUCKET, prefix + filename
        )
    _s3_client.put_object(
        Bucket=_S3_BUCKET,
        Key=prefix + "metadata.json",
        Body=json.dumps(metadata).encode("utf-8"),
    )


def _download_index_from_s3(thread_id: str):
    """Download and load a FAISS index from S3, or return (None, None) if absent."""
    if _s3_client is None:
        return None, None
    prefix = _s3_prefix(thread_id)
    try:
        objects = _s3_client.list_objects_v2(Bucket=_S3_BUCKET, Prefix=prefix)
    except Exception as exc:
        logger.error("Failed to list S3 objects for thread %s: %s", thread_id, exc)
        return None, None
    if "Contents" not in objects:
        return None, None

    with tempfile.TemporaryDirectory() as tmp_dir:
        metadata = {}
        for obj in objects["Contents"]:
            key = obj["Key"]
            filename = key[len(prefix):]
            if not filename:
                continue
            local_path = os.path.join(tmp_dir, filename)
            _s3_client.download_file(_S3_BUCKET, key, local_path)
            if filename == "metadata.json":
                with open(local_path, "r", encoding="utf-8") as f:
                    metadata = json.load(f)

        if "metadata.json" in os.listdir(tmp_dir):
            os.remove(os.path.join(tmp_dir, "metadata.json"))

        try:
            vector_store = FAISS.load_local(
                tmp_dir, embeddings, allow_dangerous_deserialization=True
            )
        except Exception as exc:
            logger.error("Failed to load FAISS index for thread %s: %s", thread_id, exc)
            return None, None

        retriever = vector_store.as_retriever(
            search_type="similarity", search_kwargs={"k": 4}
        )
        return retriever, metadata


def _get_retriever(thread_id: Optional[str]):
    """Fetch the retriever for a thread, checking the in-memory cache then S3."""
    if not thread_id:
        return None
    if thread_id in _THREAD_RETRIEVERS:
        return _THREAD_RETRIEVERS[thread_id]

    retriever, metadata = _download_index_from_s3(thread_id)
    if retriever is not None:
        _THREAD_RETRIEVERS[thread_id] = retriever
        _THREAD_METADATA[thread_id] = metadata
        logger.info("Loaded FAISS index for thread %s from S3", thread_id)
    return retriever


def ingest_pdf(file_bytes: bytes, thread_id: str, filename: Optional[str] = None) -> dict:
    """
    Build a FAISS retriever for the uploaded PDF and store it for the thread.

    Returns a summary dict that can be surfaced in the UI.
    """
    if not file_bytes:
        raise ValueError("No bytes received for ingestion.")

    with tempfile.NamedTemporaryFile(delete=False, suffix=".pdf") as temp_file:
        temp_file.write(file_bytes)
        temp_path = temp_file.name

    try:
        loader = PyPDFLoader(temp_path)
        docs = loader.load()

        splitter = RecursiveCharacterTextSplitter(
            chunk_size=1000, chunk_overlap=200, separators=["\n\n", "\n", " ", ""]
        )
        chunks = splitter.split_documents(docs)

        vector_store = FAISS.from_documents(chunks, embeddings)
        retriever = vector_store.as_retriever(
            search_type="similarity", search_kwargs={"k": 4}
        )

        metadata = {
            "filename": filename or os.path.basename(temp_path),
            "documents": len(docs),
            "chunks": len(chunks),
        }

        _THREAD_RETRIEVERS[str(thread_id)] = retriever
        _THREAD_METADATA[str(thread_id)] = metadata

        with tempfile.TemporaryDirectory() as save_dir:
            vector_store.save_local(save_dir)
            try:
                _upload_index_to_s3(str(thread_id), save_dir, metadata)
                logger.info(
                    "Uploaded FAISS index for thread %s to S3 (%s chunks)",
                    thread_id, len(chunks),
                )
            except Exception as exc:
                logger.error("Failed to upload FAISS index for thread %s: %s", thread_id, exc)

        return metadata
    finally:
        # The FAISS store keeps copies of the text, so the temp file is safe to remove.
        try:
            os.remove(temp_path)
        except OSError:
            pass


# -------------------
# 3. Tools
# -------------------
search_tool = DuckDuckGoSearchRun(region="us-en")


@tool
def calculator(first_num: float, second_num: float, operation: str) -> dict:
    """
    Perform a basic arithmetic operation on two numbers.
    Supported operations: add, sub, mul, div
    """
    try:
        if operation == "add":
            result = first_num + second_num
        elif operation == "sub":
            result = first_num - second_num
        elif operation == "mul":
            result = first_num * second_num
        elif operation == "div":
            if second_num == 0:
                return {"error": "Division by zero is not allowed"}
            result = first_num / second_num
        else:
            return {"error": f"Unsupported operation '{operation}'"}

        return {
            "first_num": first_num,
            "second_num": second_num,
            "operation": operation,
            "result": result,
        }
    except Exception as e:
        return {"error": str(e)}


@tool
def get_stock_price(symbol: str) -> dict:
    """
    Fetch latest stock price for a given symbol (e.g. 'AAPL', 'TSLA') 
    using Alpha Vantage with API key in the URL.
    """
    api_key = os.environ.get("ALPHA_VANTAGE_API_KEY")
    if not api_key:
        return {"error": "ALPHA_VANTAGE_API_KEY is not configured"}
    url = (
        "https://www.alphavantage.co/query"
        f"?function=GLOBAL_QUOTE&symbol={symbol}&apikey={api_key}"
    )
    r = requests.get(url)
    return r.json()


@tool
def rag_tool(query: str, thread_id: Optional[str] = None) -> dict:
    """
    Retrieve relevant information from the uploaded PDF for this chat thread.
    Always include the thread_id when calling this tool.
    """
    retriever = _get_retriever(thread_id)
    if retriever is None:
        return {
            "error": "No document indexed for this chat. Upload a PDF first.",
            "query": query,
        }

    result = retriever.invoke(query)
    context = [doc.page_content for doc in result]
    metadata = [doc.metadata for doc in result]

    return {
        "query": query,
        "context": context,
        "metadata": metadata,
        "source_file": _THREAD_METADATA.get(str(thread_id), {}).get("filename"),
    }


tools = [search_tool, get_stock_price, calculator, rag_tool]
llm_with_tools = llm.bind_tools(tools)

# -------------------
# 4. State
# -------------------
class ChatState(TypedDict):
    messages: Annotated[list[BaseMessage], add_messages]


# -------------------
# 5. Nodes
# -------------------
def chat_node(state: ChatState, config=None):
    """LLM node that may answer or request a tool call."""
    thread_id = None
    if config and isinstance(config, dict):
        thread_id = config.get("configurable", {}).get("thread_id")

    system_message = SystemMessage(
        content=(
            "You are a helpful assistant. For questions about the uploaded PDF, call "
            "the `rag_tool` and include the thread_id "
            f"`{thread_id}`. You can also use the web search, stock price, and "
            "calculator tools when helpful. If no document is available, ask the user "
            "to upload a PDF."
        )
    )

    messages = [system_message, *state["messages"]]
    response = llm_with_tools.invoke(messages, config=config)
    return {"messages": [response]}


tool_node = ToolNode(tools)

# -------------------
# 6. Checkpointer
# -------------------
_pool = ConnectionPool(conninfo=os.environ["DATABASE_URL"])
checkpointer = PostgresSaver(_pool)
checkpointer.setup()   # creates checkpoint tables on first run (idempotent)

# -------------------
# 7. Graph
# -------------------
graph = StateGraph(ChatState)
graph.add_node("chat_node", chat_node)
graph.add_node("tools", tool_node)

graph.add_edge(START, "chat_node")
graph.add_conditional_edges("chat_node", tools_condition)
graph.add_edge("tools", "chat_node")

chatbot = graph.compile(checkpointer=checkpointer)

# -------------------
# 8. Helpers
# -------------------
def retrieve_all_threads():
    all_threads = set()
    for checkpoint in checkpointer.list(None):
        all_threads.add(checkpoint.config["configurable"]["thread_id"])
    return list(all_threads)


def thread_has_document(thread_id: str) -> bool:
    return _get_retriever(str(thread_id)) is not None


def thread_document_metadata(thread_id: str) -> dict:
    return _THREAD_METADATA.get(str(thread_id), {})