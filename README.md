# LLMTools

This repository contains PowerShell scripts for processing PDF files and generating embeddings for use with RAG systems.

## Requirements

- PowerShell 7.0 or later
- Python 3.8 or later with required packages
- OCR tools depending on selected method

## Scripts

### ConvertPDFsToMarkdown.ps1

A script that processes PDF files and converts them to Markdown format using various OCR tools.

```powershell
# Basic usage
.\ConvertPDFsToMarkdown.ps1 -SourceDirectory "C:\PDFSource" -OutputDirectory "C:\PDFOutput"

# Using different OCR tools
.\ConvertPDFsToMarkdown.ps1 -SourceDirectory "C:\PDFSource" -OutputDirectory "C:\PDFOutput" -OcrTool "tesseract"

# Watch mode for continuous processing
.\ConvertPDFsToMarkdown.ps1 -SourceDirectory "C:\PDFSource" -OutputDirectory "C:\PDFOutput" -WatchMode
```

### CreateChromaEmbeddings.ps1

A script that creates ChromaDB embeddings from text files using Ollama API.

```powershell
# Basic usage
.\CreateChromaEmbeddings.ps1 -FolderPath "C:\PDFOutput" -OutputFolder ".\chroma_db"

# Watch mode for continuous updates
.\CreateChromaEmbeddings.ps1 -FolderPath "C:\PDFOutput" -OutputFolder ".\chroma_db" -WatchMode
```

## REST API

The repository now includes a REST API that allows you to monitor and control synchronization operations remotely.

### ApiServer.ps1

A REST API server that provides endpoints to check progress, start, and stop synchronization operations.

```powershell
# Start the API server with default settings (localhost:8080)
.\ApiServer.ps1

# Start with custom settings
.\ApiServer.ps1 -ListenAddress "0.0.0.0" -Port 9000
```

### SyncClient.ps1

A client script to interact with the Synchronization REST API.

```powershell
# Check API connection
.\SyncClient.ps1 -Command check

# Start PDF to Markdown conversion
.\SyncClient.ps1 -Command start-pdf -SourceDirectory "C:\PDFSource" -OutputDirectory "C:\PDFOutput"

# Start Chroma embedding generation
.\SyncClient.ps1 -Command start-chroma -FolderPath "C:\PDFOutput"

# Monitor a job with live updates
.\SyncClient.ps1 -Command monitor -JobId "job-1-12345"
```

For detailed API documentation, see [API_Documentation.md](API_Documentation.md).
