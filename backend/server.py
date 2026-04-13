from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from openai import OpenAI
import os
from dotenv import load_dotenv
from typing import Optional, List, Dict
import json
import traceback
import uuid
from datetime import datetime
import boto3
from botocore.exceptions import ClientError
from context import prompt

# Load .env for local dev only; Lambda uses real env from Terraform (avoid cwd .env shadowing).
if not os.getenv("AWS_LAMBDA_FUNCTION_NAME"):
    load_dotenv()

app = FastAPI()

# Configure CORS: in Lambda, allow any Origin (CloudFront, S3 static website, localhost API tests).
# API Gateway HTTP API also emits CORS headers; this keeps FastAPI responses consistent for browsers.
if os.getenv("AWS_LAMBDA_FUNCTION_NAME"):
    origins = ["*"]
else:
    origins = [
        o.strip()
        for o in os.getenv("CORS_ORIGINS", "http://localhost:3000").split(",")
        if o.strip()
    ]
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)

def _normalize_openrouter_api_key(raw: str | None) -> str:
    if not raw:
        return ""
    s = raw.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ('"', "'"):
        s = s[1:-1].strip()
    return s.removeprefix("\ufeff").strip()


def _openrouter_client() -> OpenAI:
    key = _normalize_openrouter_api_key(os.getenv("OPENROUTER_API_KEY"))
    if not key:
        raise ValueError("OPENROUTER_API_KEY is not set")
    base = (os.getenv("OPENROUTER_BASE_URL") or "https://openrouter.ai/api/v1").strip()
    referer = (os.getenv("OPENROUTER_HTTP_REFERER") or "").strip() or "https://github.com"
    title = (os.getenv("OPENROUTER_APP_TITLE") or "").strip() or "digital-twin-api"
    return OpenAI(
        api_key=key,
        base_url=base,
        default_headers={
            "HTTP-Referer": referer,
            "X-Title": title,
        },
    )

# Memory storage configuration
USE_S3 = os.getenv("USE_S3", "false").lower() == "true"
S3_BUCKET = os.getenv("S3_BUCKET", "")
MEMORY_DIR = os.getenv("MEMORY_DIR", "../memory")

# Initialize S3 client if needed
if USE_S3:
    s3_client = boto3.client("s3")


# Request/Response models
class ChatRequest(BaseModel):
    message: str
    session_id: Optional[str] = None


class ChatResponse(BaseModel):
    response: str
    session_id: str


class Message(BaseModel):
    role: str
    content: str
    timestamp: str


# Memory management functions
def get_memory_path(session_id: str) -> str:
    return f"{session_id}.json"


def load_conversation(session_id: str) -> List[Dict]:
    """Load conversation history from storage"""
    if USE_S3:
        try:
            response = s3_client.get_object(Bucket=S3_BUCKET, Key=get_memory_path(session_id))
            return json.loads(response["Body"].read().decode("utf-8"))
        except ClientError as e:
            if e.response["Error"]["Code"] == "NoSuchKey":
                return []
            raise
    else:
        # Local file storage
        file_path = os.path.join(MEMORY_DIR, get_memory_path(session_id))
        if os.path.exists(file_path):
            with open(file_path, "r") as f:
                return json.load(f)
        return []


def save_conversation(session_id: str, messages: List[Dict]):
    """Save conversation history to storage"""
    if USE_S3:
        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=get_memory_path(session_id),
            Body=json.dumps(messages, indent=2),
            ContentType="application/json",
        )
    else:
        # Local file storage
        os.makedirs(MEMORY_DIR, exist_ok=True)
        file_path = os.path.join(MEMORY_DIR, get_memory_path(session_id))
        with open(file_path, "w") as f:
            json.dump(messages, f, indent=2)


@app.get("/")
async def root():
    return {
        "message": "AI Digital Twin API",
        "memory_enabled": True,
        "storage": "S3" if USE_S3 else "local",
    }


@app.get("/health")
async def health_check():
    return {"status": "healthy", "use_s3": USE_S3}


@app.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):
    try:
        # Generate session ID if not provided
        session_id = request.session_id or str(uuid.uuid4())

        # Load conversation history
        conversation = load_conversation(session_id)

        # Build messages for OpenAI
        messages = [{"role": "system", "content": prompt()}]

        # Add conversation history (keep last 10 messages for context window)
        for msg in conversation[-10:]:
            messages.append({"role": msg["role"], "content": msg["content"]})

        # Add current user message
        messages.append({"role": "user", "content": request.message})

        # OpenRouter via OpenAI SDK (new client each call so Lambda env is current; headers per OpenRouter docs).
        response = _openrouter_client().chat.completions.create(
            model="openai/gpt-4o-mini",
            messages=messages,
        )

        if not response.choices:
            raise ValueError("OpenRouter returned no completion choices")
        msg = response.choices[0].message
        assistant_response = (msg.content or "").strip()
        if not assistant_response:
            raise ValueError("OpenRouter returned an empty assistant message")

        # Update conversation history
        conversation.append(
            {"role": "user", "content": request.message, "timestamp": datetime.now().isoformat()}
        )
        conversation.append(
            {
                "role": "assistant",
                "content": assistant_response,
                "timestamp": datetime.now().isoformat(),
            }
        )

        # Save conversation
        save_conversation(session_id, conversation)

        return ChatResponse(response=assistant_response, session_id=session_id)

    except Exception as e:
        print(f"Error in chat endpoint: {str(e)}\n{traceback.format_exc()}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/conversation/{session_id}")
async def get_conversation(session_id: str):
    """Retrieve conversation history"""
    try:
        conversation = load_conversation(session_id)
        return {"session_id": session_id, "messages": conversation}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)