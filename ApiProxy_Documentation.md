# REST API Proxy for ChromaDB & Ollama

This documentation describes the REST API proxy provided by the `ApiProxy.ps1` script, which enhances chat completions with relevant context from a ChromaDB vector database.

## Overview

The API proxy sits between your application and Ollama's API, providing the following features:

- **Context-Enriched Chat**: Automatically retrieves relevant documents from ChromaDB based on user queries
- **Semantic Search**: Directly search ChromaDB for relevant documents using vector similarity
- **Configurable Relevance**: Adjust similarity threshold and maximum context documents
- **Transparent Metadata**: Includes information about sources used for context in responses

## Prerequisites

- PowerShell 7.0 or later
- Python 3.8 or later with the following packages:
  - `chromadb`
  - `requests`
  - `numpy`
- Ollama running locally or on a remote server
- A populated ChromaDB database (created using `CreateChromaEmbeddings.ps1`)

## API Proxy Setup

Run the API proxy using PowerShell 7.0 or later:

```powershell
# Start the API proxy with default settings (localhost:8081)
.\ApiProxy.ps1

# Start with custom settings
.\ApiProxy.ps1 -ListenAddress "0.0.0.0" -Port 9000 -ChromaDbPath ".\my_chroma_db" -OllamaUrl "http://ollama:11434"

# Configure relevance parameters
.\ApiProxy.ps1 -RelevanceThreshold 0.8 -MaxContextDocs 3
```

### Configuration Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `ListenAddress` | IP address to listen on | `localhost` |
| `Port` | Port to listen on | `8081` |
| `ChromaDbPath` | Path to ChromaDB database | `./chroma_db` |
| `OllamaUrl` | URL of Ollama API | `http://localhost:11434` |
| `EmbeddingModel` | Embedding model to use | `mxbai-embed-large:latest` |
| `RelevanceThreshold` | Minimum similarity score (0-1) for including context | `0.75` |
| `MaxContextDocs` | Maximum number of context documents to include | `5` |
| `UseHttps` | Use HTTPS instead of HTTP | `false` |

## Available Endpoints

### 1. Health Check & API Information

**Endpoint:** `GET /`

**Description:** Returns information about the API proxy and available routes.

**Sample Response:**
```json
{
  "status": "ok",
  "message": "API proxy running",
  "routes": [
    "/api/chat - POST: Chat with context augmentation",
    "/api/search - POST: Search for relevant documents",
    "/status - GET: Get API proxy status"
  ]
}
```

### 2. API Status

**Endpoint:** `GET /status`

**Description:** Returns the current configuration of the API proxy.

**Sample Response:**
```json
{
  "status": "ok",
  "chromaDbPath": "./chroma_db",
  "ollamaUrl": "http://localhost:11434",
  "embeddingModel": "mxbai-embed-large:latest",
  "relevanceThreshold": 0.75,
  "maxContextDocs": 5
}
```

### 3. Search for Relevant Documents

**Endpoint:** `POST /api/search`

**Description:** Search ChromaDB for documents relevant to a query without generating a chat response.

**Request Body:**
```json
{
  "query": "What is a RAG system?",
  "max_results": 3,
  "threshold": 0.8
}
```

**Parameters:**
- `query` (required): The search query
- `max_results` (optional): Maximum number of results to return (default: value of `MaxContextDocs` parameter)
- `threshold` (optional): Minimum similarity threshold (default: value of `RelevanceThreshold` parameter)

**Sample Response:**
```json
{
  "success": true,
  "query": "What is a RAG system?",
  "results": [
    {
      "document": "RAG (Retrieval-Augmented Generation) is a technique that enhances large language models by retrieving relevant context from external knowledge sources...",
      "metadata": {
        "source": "C:\\PDFOutput\\ai_techniques.md",
        "start_line": 120,
        "end_line": 145,
        "line_range": "120-145"
      },
      "similarity": 0.92
    },
    {
      "document": "Modern RAG systems use vector databases to store embeddings of documents for efficient similarity search...",
      "metadata": {
        "source": "C:\\PDFOutput\\vector_databases.md",
        "start_line": 35,
        "end_line": 52,
        "line_range": "35-52"
      },
      "similarity": 0.87
    }
  ],
  "count": 2
}
```

### 4. Chat with Context Augmentation

**Endpoint:** `POST /api/chat`

**Description:** Send a chat request that will be automatically enhanced with relevant context before forwarding to Ollama.

**Request Body:**
```json
{
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "What is a RAG system and how does it improve LLM responses?"}
  ],
  "model": "llama3",
  "max_context_docs": 3,
  "threshold": 0.8,
  "enhance_context": true
}
```

**Parameters:**
- `messages` (required): Array of chat messages in the standard format (role/content pairs)
- `model` (optional): Ollama model to use (default: "llama3")
- `max_context_docs` (optional): Maximum number of context documents to include (default: value of `MaxContextDocs` parameter)
- `threshold` (optional): Minimum similarity threshold (default: value of `RelevanceThreshold` parameter)
- `enhance_context` (optional): Whether to add relevant context from ChromaDB (default: true)
- `context` (optional): Raw Ollama context ID for continuing a conversation

**Sample Response:**
```json
{
  "message": {
    "role": "assistant",
    "content": "A RAG (Retrieval-Augmented Generation) system is an approach that enhances Large Language Models (LLMs) by combining them with a retrieval component that fetches relevant information from a knowledge base...[detailed response]"
  },
  "context_count": 2,
  "context_info": [
    {
      "source": "ai_techniques.md",
      "line_range": "120-145",
      "similarity": 0.92
    },
    {
      "source": "vector_databases.md",
      "line_range": "35-52",
      "similarity": 0.87
    }
  ]
}
```

## How It Works

1. When a chat request is received, the proxy extracts the latest user message
2. It queries ChromaDB for documents semantically similar to the user's message
3. Relevant documents (those above the similarity threshold) are formatted as context
4. This context is added to the system message or a new system message is created
5. The enhanced request is forwarded to Ollama's API
6. Ollama's response is returned along with metadata about the context used

## Example Usage

### Using cURL

```bash
# Health check
curl -X GET http://localhost:8081/

# Status check
curl -X GET http://localhost:8081/status

# Search for relevant documents
curl -X POST http://localhost:8081/api/search \
  -H "Content-Type: application/json" \
  -d '{
    "query": "How does ChromaDB work with embeddings?"
  }'

# Chat with context enhancement
curl -X POST http://localhost:8081/api/chat \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "How does ChromaDB work with embeddings?"}
    ],
    "model": "llama3"
  }'
```

### Using PowerShell

```powershell
# Health check
Invoke-RestMethod -Method GET -Uri "http://localhost:8081/"

# Status check
Invoke-RestMethod -Method GET -Uri "http://localhost:8081/status"

# Search for relevant documents
$searchBody = @{
    query = "How does ChromaDB work with embeddings?"
} | ConvertTo-Json

Invoke-RestMethod -Method POST -Uri "http://localhost:8081/api/search" -Body $searchBody -ContentType "application/json"

# Chat with context enhancement
$chatBody = @{
    messages = @(
        @{
            role = "system"
            content = "You are a helpful assistant."
        },
        @{
            role = "user"
            content = "How does ChromaDB work with embeddings?"
        }
    )
    model = "llama3"
} | ConvertTo-Json

Invoke-RestMethod -Method POST -Uri "http://localhost:8081/api/chat" -Body $chatBody -ContentType "application/json"
```

## Workflow for Creating and Using the API Proxy

1. **Generate embeddings** for your documents:
   ```powershell
   .\CreateChromaEmbeddings.ps1 -FolderPath "C:\YourDocuments" -OutputFolder ".\chroma_db"
   ```

2. **Start the API proxy**:
   ```powershell
   .\ApiProxy.ps1 -ChromaDbPath ".\chroma_db"
   ```

3. **Send requests** to the proxy instead of directly to Ollama

## Troubleshooting

- Check the `api-proxy.log` file in the script directory for detailed logs
- Ensure ChromaDB is populated with documents
- Verify that Ollama is running and accessible
- If no relevant context is found, try lowering the relevance threshold
- If queries are slow, consider reducing the maximum context documents
