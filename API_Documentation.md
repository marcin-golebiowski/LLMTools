# REST API Documentation for Synchronization Operations

This documentation describes the REST API provided by the `ApiServer.ps1` script, which allows you to monitor and control PDF-to-Markdown conversion and Chroma embedding generation operations.

## API Server Setup

Run the API server using PowerShell 7.0 or later:

```powershell
# Start the API server with default settings (localhost:8080)
.\ApiServer.ps1

# Start with custom settings
.\ApiServer.ps1 -ListenAddress "0.0.0.0" -Port 9000

# Start with HTTPS (requires certificate configuration)
.\ApiServer.ps1 -UseHttps
```

## Available Endpoints

### 1. Health Check & API Information

**Endpoint:** `GET /`

**Description:** Returns information about the API server and available routes.

**Sample Response:**
```json
{
  "status": "ok",
  "message": "API server running",
  "routes": [
    "/jobs - GET: List all jobs",
    "/jobs/pdf - POST: Start PDF to Markdown conversion",
    "/jobs/chroma - POST: Start Chroma embedding generation",
    "/jobs/{id} - GET: Get job status",
    "/jobs/{id}/stop - POST: Stop a running job"
  ]
}
```

### 2. List All Jobs

**Endpoint:** `GET /jobs`

**Description:** Returns a list of all jobs (running, completed, and failed) along with their status information.

**Sample Response:**
```json
{
  "count": 2,
  "jobs": [
    {
      "jobId": "job-1-12345",
      "type": "pdfToMarkdown",
      "status": {
        "jobId": "job-1-12345",
        "state": "running",
        "details": "Processing file: example.pdf",
        "progress": 50,
        "startTime": "2025-03-12T19:30:00.0000000+01:00",
        "runtime": 300
      }
    },
    {
      "jobId": "job-2-67890",
      "type": "chromaEmbedding",
      "status": {
        "jobId": "job-2-67890",
        "state": "completed",
        "details": "Completed processing 42 of 42 files",
        "progress": 100,
        "processed": 42,
        "totalFiles": 42,
        "startTime": "2025-03-12T19:20:00.0000000+01:00",
        "runtime": 900
      }
    }
  ]
}
```

### 3. Start PDF to Markdown Conversion

**Endpoint:** `POST /jobs/pdf`

**Description:** Starts a new PDF to Markdown conversion job.

**Request Body:**
```json
{
  "sourceDirectory": "C:\\PDFSource",
  "outputDirectory": "C:\\PDFOutput",
  "watchMode": false,
  "pollingInterval": 30,
  "removeOriginals": false,
  "ocrTool": "marker"
}
```

**Parameters:**
- `sourceDirectory` (required): Directory containing PDF files to convert
- `outputDirectory` (required): Directory to save converted Markdown files
- `watchMode` (optional): Enable monitoring for new files (default: false)
- `pollingInterval` (optional): Interval in seconds to check for new files in watch mode (default: 30)
- `removeOriginals` (optional): Remove original PDF files after conversion (default: false)
- `ocrTool` (optional): OCR tool to use ["marker", "tesseract", "ocrmypdf", "pymupdf"] (default: "marker")

**Sample Response:**
```json
{
  "jobId": "job-3-24680",
  "state": "running",
  "details": "PDF to Markdown conversion started"
}
```

### 4. Start Chroma Embedding Generation

**Endpoint:** `POST /jobs/chroma`

**Description:** Starts a new Chroma embedding generation job.

**Request Body:**
```json
{
  "folderPath": "C:\\PDFOutput",
  "extensions": ".txt,.md,.html,.csv,.json",
  "outputFolder": "./chroma_db",
  "ollamaUrl": "http://localhost:11434",
  "embeddingModel": "mxbai-embed-large:latest",
  "chunkSize": 100000,
  "watchMode": false
}
```

**Parameters:**
- `folderPath` (required): Directory containing text files to process
- `extensions` (optional): Comma-separated list of file extensions to process (default: ".txt,.md,.html,.csv,.json")
- `outputFolder` (optional): Directory to save Chroma database (default: "./chroma_db")
- `ollamaUrl` (optional): URL of Ollama API (default: "http://localhost:11434")
- `embeddingModel` (optional): Embedding model to use (default: "mxbai-embed-large:latest")
- `chunkSize` (optional): Maximum size of text chunks in characters (default: 100000)
- `watchMode` (optional): Enable monitoring for file changes (default: false)

**Sample Response:**
```json
{
  "jobId": "job-4-13579",
  "state": "running",
  "details": "Chroma embedding generation started"
}
```

### 5. Get Job Status

**Endpoint:** `GET /jobs/{jobId}`

**Description:** Gets the status of a specific job.

**Parameters:**
- `jobId` (path parameter): The ID of the job to check

**Sample Response for PDF to Markdown Job:**
```json
{
  "jobId": "job-1-12345",
  "state": "running",
  "details": "Processing file: example.pdf",
  "progress": 50,
  "startTime": "2025-03-12T19:30:00.0000000+01:00",
  "runtime": 300
}
```

**Sample Response for Chroma Embedding Job:**
```json
{
  "jobId": "job-2-67890",
  "state": "completed",
  "details": "Completed processing 42 of 42 files",
  "progress": 100,
  "processed": 42,
  "totalFiles": 42,
  "startTime": "2025-03-12T19:20:00.0000000+01:00",
  "runtime": 900
}
```

**Job States:**
- `running`: Job is still in progress
- `completed`: Job has completed successfully
- `failed`: Job has failed (check details for error message)
- `stopped`: Job was stopped by user
- `unknown`: Job state could not be determined

### 6. Stop a Running Job

**Endpoint:** `POST /jobs/{jobId}/stop`

**Description:** Stops a running job.

**Parameters:**
- `jobId` (path parameter): The ID of the job to stop

**Sample Response:**
```json
{
  "jobId": "job-1-12345",
  "state": "stopped",
  "details": "Job stopped successfully"
}
```

## Using the API with cURL

Here are some examples of how to use the API with cURL:

### Check API status:
```bash
curl -X GET http://localhost:8080/
```

### List all jobs:
```bash
curl -X GET http://localhost:8080/jobs
```

### Start PDF to Markdown conversion:
```bash
curl -X POST http://localhost:8080/jobs/pdf \
  -H "Content-Type: application/json" \
  -d '{
    "sourceDirectory": "C:\\PDFSource",
    "outputDirectory": "C:\\PDFOutput",
    "ocrTool": "marker"
  }'
```

### Start Chroma embedding generation:
```bash
curl -X POST http://localhost:8080/jobs/chroma \
  -H "Content-Type: application/json" \
  -d '{
    "folderPath": "C:\\PDFOutput",
    "outputFolder": ".\\chroma_db"
  }'
```

### Check job status:
```bash
curl -X GET http://localhost:8080/jobs/job-1-12345
```

### Stop a job:
```bash
curl -X POST http://localhost:8080/jobs/job-1-12345/stop
```

## Using the API with PowerShell

Here are some examples of how to use the API with PowerShell:

### Check API status:
```powershell
Invoke-RestMethod -Method GET -Uri "http://localhost:8080/"
```

### List all jobs:
```powershell
Invoke-RestMethod -Method GET -Uri "http://localhost:8080/jobs"
```

### Start PDF to Markdown conversion:
```powershell
$body = @{
    sourceDirectory = "C:\PDFSource"
    outputDirectory = "C:\PDFOutput"
    ocrTool = "marker"
} | ConvertTo-Json

Invoke-RestMethod -Method POST -Uri "http://localhost:8080/jobs/pdf" -Body $body -ContentType "application/json"
```

### Start Chroma embedding generation:
```powershell
$body = @{
    folderPath = "C:\PDFOutput"
    outputFolder = ".\chroma_db"
} | ConvertTo-Json

Invoke-RestMethod -Method POST -Uri "http://localhost:8080/jobs/chroma" -Body $body -ContentType "application/json"
```

### Check job status:
```powershell
Invoke-RestMethod -Method GET -Uri "http://localhost:8080/jobs/job-1-12345"
```

### Stop a job:
```powershell
Invoke-RestMethod -Method POST -Uri "http://localhost:8080/jobs/job-1-12345/stop"
```
