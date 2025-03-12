# CreateChromaEmbeddings.ps1
# Creates a ChromaDB with embeddings from text files in a specified directory
# Uses Ollama API for generating embeddings
# Supports watch mode to monitor for file changes

#Requires -Version 7.0

param(
    [Parameter(Mandatory=$true)]
    [string]$FolderPath,
    
    [Parameter(Mandatory=$false)]
    [string]$Extensions = ".txt,.md,.html,.csv,.json",
    
    [Parameter(Mandatory=$false)]
    [string]$OutputFolder = "./chroma_db",
    
    [Parameter(Mandatory=$false)]
    [string]$OllamaUrl = "http://localhost:11434",
    
    [Parameter(Mandatory=$false)]
    [string]$EmbeddingModel = "mxbai-embed-large:latest",
    
    [Parameter(Mandatory=$false)]
    [int]$ChunkSize = 100000,
    
    [Parameter(Mandatory=$false)]
    [switch]$WatchMode
)

# Check if Python is installed
try {
    $pythonVersion = python --version
    Write-Host "Found Python: $pythonVersion" -ForegroundColor Green
}
catch {
    Write-Host "Python not found. Please install Python 3.8+ to use this script." -ForegroundColor Red
    exit 1
}

# Install required packages if not already installed
function Ensure-Package {
    param([string]$PackageName)
    
    $installed = python -c "try: 
        import $PackageName
        print('installed')
    except ImportError: 
        print('not installed')" 2>$null
    
    if ($installed -ne "installed") {
        Write-Host "Installing $PackageName..." -ForegroundColor Yellow
        python -m pip install $PackageName
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to install $PackageName. Please install it manually with 'pip install $PackageName'" -ForegroundColor Red
            exit 1
        }
        Write-Host "$PackageName installed successfully." -ForegroundColor Green
    }
    else {
        Write-Host "$PackageName is already installed." -ForegroundColor Green
    }
}

Write-Host "Checking for required Python packages..." -ForegroundColor Cyan
Ensure-Package "chromadb"
Ensure-Package "requests"
Ensure-Package "numpy"

# Verify the folder path exists
if (-not (Test-Path -Path $FolderPath)) {
    Write-Host "The specified folder path does not exist: $FolderPath" -ForegroundColor Red
    exit 1
}

# Check if Ollama is running
Write-Host "Checking if Ollama is running at $OllamaUrl..." -ForegroundColor Cyan
$ollamaStatus = python -c "
import requests
import sys
try:
    response = requests.get('$OllamaUrl/api/tags')
    if response.status_code == 200:
        print('Ollama is running')
        models = response.json().get('models', [])
        available_models = [model['name'] for model in models]
        if '$EmbeddingModel' in available_models:
            print('Model $EmbeddingModel is available')
        else:
            print('WARNING: Model $EmbeddingModel is not available')
            print('Available models: ' + ', '.join(available_models))
    else:
        print('Ollama is not responding correctly')
        sys.exit(1)
except Exception as e:
    print(f'Error connecting to Ollama: {e}')
    sys.exit(1)
" 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "Ollama is not running or not accessible at $OllamaUrl" -ForegroundColor Red
    Write-Host "Please ensure Ollama is running before proceeding." -ForegroundColor Red
    Write-Host "You can download Ollama from https://ollama.ai/" -ForegroundColor Cyan
    exit 1
}

foreach ($line in $ollamaStatus) {
    if ($line -like "*WARNING*") {
        Write-Host $line -ForegroundColor Yellow
    } else {
        Write-Host $line -ForegroundColor Green
    }
}

# Create the temporary Python script for generating embeddings
$tempPythonScript = [System.IO.Path]::GetTempFileName() + ".py"

$pythonCode = @"
import os
import sys
import chromadb
import json
import argparse
import urllib.request
import urllib.error
import numpy as np
import re
from chromadb.config import Settings
import time

def get_embedding_from_ollama(text, model="llama3", base_url="http://localhost:11434"):
    """
    Get embeddings from Ollama API
    
    Args:
        text (str): The text to get embeddings for
        model (str): The model to use (default: "llama3")
        base_url (str): The base URL for Ollama API (default: "http://localhost:11434")
        
    Returns:
        list: A list of embedding values
    """
    url = f"{base_url}/api/embeddings"
    
    # Prepare request data
    data = {
        "model": model,
        "prompt": text
    }
    
    # Convert data to JSON and encode as bytes
    data_bytes = json.dumps(data).encode('utf-8')
    
    # Set headers
    headers = {
        'Content-Type': 'application/json'
    }
    
    # Create request
    req = urllib.request.Request(url, data=data_bytes, headers=headers, method="POST")
    
    # Send request and get response
    try:
        with urllib.request.urlopen(req) as response:
            response_text = response.read().decode('utf-8')
            
            # Debug: Print raw response
            print(f"Raw response: {response_text}")
            
            # Parse JSON response
            try:
                response_data = json.loads(response_text)
            except json.JSONDecodeError:
                print("Failed to parse JSON response. Raw response:")
                print(response_text)
                return []
            
            # Debug: Print response structure
            print(f"Response type: {type(response_data)}")
            if isinstance(response_data, dict):
                print(f"Response keys: {list(response_data.keys())}")
            elif isinstance(response_data, list):
                print(f"Response is a list with {len(response_data)} items")
                if response_data and isinstance(response_data[0], dict):
                    print(f"First item keys: {list(response_data[0].keys())}")
            
            # Handle different response formats
            if isinstance(response_data, dict):
                # Standard format: {"embedding": [...]}
                if 'embedding' in response_data:
                    return response_data['embedding']
                
                # Alternative format: {"embeddings": [...]}
                elif 'embeddings' in response_data:
                    embeddings = response_data['embeddings']
                    # Handle if embeddings is a list of lists
                    if embeddings and isinstance(embeddings[0], list):
                        return embeddings[0]  # Return first embedding
                    return embeddings
            
            # Handle list format, e.g. [{...}, {...}]
            elif isinstance(response_data, list) and response_data:
                if isinstance(response_data[0], dict):
                    # Try to find embeddings in the first item
                    first_item = response_data[0]
                    if 'embedding' in first_item:
                        return first_item['embedding']
                    elif 'embeddings' in first_item:
                        return first_item['embeddings']
                # Maybe the response is directly a list of floats
                elif isinstance(response_data[0], (int, float)):
                    return response_data
            
            # If we got here, we couldn't identify the embedding format
            print(f"Could not identify embedding format in response: {response_data}")
            return []
            
    except urllib.error.URLError as e:
        print(f"Error connecting to Ollama: {e}")
        return []


def create_or_get_collection(output_folder):
    """Setup ChromaDB without embedding function"""
    chroma_client = chromadb.PersistentClient(path=output_folder, settings=Settings(anonymized_telemetry=False))
    
    # Get or create collection without embedding function
    collection = chroma_client.get_or_create_collection(
        name="document_collection"
    )
    return collection

def process_single_file(file_path, folder_path, collection, chunk_size, model_name, api_url):
    try:
        # Read file content and track line numbers
        lines = []
        with open(file_path, 'r', encoding='utf-8', errors='replace') as f:
            for i, line in enumerate(f):
                lines.append((i + 1, line))
        
        # Skip empty files
        if not lines:
            return False
        
        # Reassemble content for processing
        content = "".join([line for _, line in lines])
        
        # Skip empty files
        if not content.strip():
            return False
        
        # Create doc_id from relative path
        doc_id = os.path.relpath(file_path, folder_path).replace("\\", "/")
        
        # Remove any existing entries for this file
        try:
            collection.delete(where={"source": file_path})
        except Exception:
            pass  # Ignore errors if document doesn't exist
            
        try:
            # Also try deleting by ID pattern
            existing_ids = collection.get(ids=[doc_id])
            if existing_ids["ids"]:
                collection.delete(ids=[doc_id])
            
            # Try to find chunked IDs
            for i in range(1, 100):  # Reasonable upper limit for chunks
                chunk_id = f"{doc_id}_chunk_{i}"
                try:
                    existing = collection.get(ids=[chunk_id])
                    if existing["ids"]:
                        collection.delete(ids=[chunk_id])
                    else:
                        break  # Stop if no more chunks found
                except:
                    break
        except Exception:
            pass  # Ignore errors if documents don't exist
        
        # Split text into sentences
        def split_into_sentences(text):
            # Pattern for sentence boundaries: period, question mark, or exclamation mark 
            # followed by space or newline or end of string
            sentence_boundaries = re.compile(r'[.!?][\s\n]|[.!?]$')
            
            # Find all boundaries
            boundaries = [match.start() + 1 for match in sentence_boundaries.finditer(text)]
            
            # Add beginning and end indices
            boundaries = [0] + boundaries + [len(text)]
            
            # Create sentences
            sentences = []
            for i in range(len(boundaries) - 1):
                # Get sentence from current boundary to next
                start = boundaries[i]
                end = boundaries[i+1]
                
                # Trim whitespace and add to list if not empty
                sentence = text[start:end].strip()
                if sentence:
                    sentences.append(sentence)
            
            return sentences
        
        # Create chunks if needed
        if len(content) > chunk_size:
            # Split into sentences first
            sentences = split_into_sentences(content)
            
            # Create chunks of sentences, tracking line numbers
            chunks = []
            chunk_line_ranges = []
            current_chunk = ""
            current_chunk_start_line = 1
            current_line_idx = 0
            sentence_start_line = 1
            
            # Map each sentence to line numbers
            sentence_line_map = []
            current_line = 1
            current_line_content = lines[0][1] if lines else ""
            current_line_pos = 0
            content_pos = 0
            
            # Create a mapping of content positions to line numbers
            content_to_line_map = {}
            current_pos = 0
            for line_num, line_content in lines:
                line_length = len(line_content)
                for i in range(line_length):
                    content_to_line_map[current_pos + i] = line_num
                current_pos += line_length
            
            # Process sentences to form chunks
            current_chunk = ""
            chunk_start_pos = 0
            chunks = []
            chunk_line_ranges = []
            
            for sentence in sentences:
                # Check if adding this sentence would exceed chunk size
                if len(current_chunk) + len(sentence) > chunk_size and current_chunk:
                    # Store current chunk and start a new one
                    chunks.append(current_chunk)
                    
                    # Find the start and end line numbers for this chunk
                    chunk_start_line = content_to_line_map.get(chunk_start_pos, 1)
                    chunk_end_pos = chunk_start_pos + len(current_chunk) - 1
                    chunk_end_line = content_to_line_map.get(chunk_end_pos, lines[-1][0])
                    
                    chunk_line_ranges.append((chunk_start_line, chunk_end_line))
                    
                    # Start a new chunk with this sentence
                    current_chunk = sentence
                    chunk_start_pos = content.find(sentence)
                else:
                    # Add sentence to current chunk
                    if current_chunk:
                        current_chunk += " " + sentence
                    else:
                        current_chunk = sentence
                        chunk_start_pos = content.find(sentence)
            
            # Add the last chunk if it's not empty
            if current_chunk:
                chunks.append(current_chunk)
                
                # Find the line range for the last chunk
                chunk_start_line = content_to_line_map.get(chunk_start_pos, 1)
                chunk_end_pos = chunk_start_pos + len(current_chunk) - 1
                chunk_end_line = content_to_line_map.get(chunk_end_pos, lines[-1][0])
                
                chunk_line_ranges.append((chunk_start_line, chunk_end_line))
            
            # Add chunks to collection with line number metadata
            for chunk_idx, (chunk, line_range) in enumerate(zip(chunks, chunk_line_ranges)):
                # Get embedding from Ollama
                embedding = get_embedding_from_ollama(chunk, model_name, api_url)
                if embedding is None:
                    print(f"STATUS:ERROR:Failed to get embedding for chunk {chunk_idx+1} of {file_path}")
                    continue
                    
                collection.add(
                    documents=[chunk],
                    embeddings=embedding,
                    metadatas=[{
                        "source": file_path, 
                        "chunk": chunk_idx + 1, 
                        "total_chunks": len(chunks),
                        "start_line": line_range[0],
                        "end_line": line_range[1],
                        "line_range": f"{line_range[0]}-{line_range[1]}"
                    }],
                    ids=[f"{doc_id}_chunk_{chunk_idx + 1}"]
                )
        else:
            # Add document as single chunk with line number metadata
            embedding = get_embedding_from_ollama(content, model_name, api_url)
            if embedding is None:
                print(f"STATUS:ERROR:Failed to get embedding for {file_path}")
                return False
                
            collection.add(
                documents=[content],
                embeddings=[embedding],
                metadatas=[{
                    "source": file_path,
                    "start_line": 1,
                    "end_line": len(lines),
                    "line_range": f"1-{len(lines)}"
                }],
                ids=[doc_id]
            )
        return True
    except Exception as e:
        print(f"STATUS:ERROR:{file_path}:{str(e)}")
        return False

def process_files(folder_path, extensions, output_folder, model_name, api_url, chunk_size):
    # Get or create collection
    collection = create_or_get_collection(output_folder)
    
    # Get list of files
    all_files = []
    for root, _, files in os.walk(folder_path):
        for file in files:
            if any(file.lower().endswith(ext.lower()) for ext in extensions):
                all_files.append(os.path.join(root, file))
    
    total_files = len(all_files)
    if total_files == 0:
        print(f"STATUS:ERROR:No files found with extensions {extensions} in {folder_path}")
        return
    
    print(f"STATUS:INFO:Found {total_files} files to process")
    
    # Process each file
    successful = 0
    for i, file_path in enumerate(all_files):
        # Report progress
        percentage = round(((i + 1) / total_files) * 100, 2)
        print(f"STATUS:PROGRESS:{i + 1}:{total_files}:{percentage}:{file_path}")
        
        if process_single_file(file_path, folder_path, collection, chunk_size, model_name, api_url):
            successful += 1
                
    # Report completion
    print(f"STATUS:COMPLETE:{successful}:{total_files}")

def handle_file_event(file_path, folder_path, extensions, output_folder, model_name, api_url, chunk_size, event_type):
    # Check if file has a relevant extension
    if not any(file_path.lower().endswith(ext.lower()) for ext in extensions):
        return
    
    # Get collection
    collection = create_or_get_collection(output_folder)
    
    # Handle the event
    if event_type in ["created", "changed"]:
        print(f"STATUS:WATCH:{event_type}:{file_path}")
        process_single_file(file_path, folder_path, collection, chunk_size, model_name, api_url)
    elif event_type == "deleted":
        print(f"STATUS:WATCH:deleted:{file_path}")
        # Create doc_id from relative path
        doc_id = os.path.relpath(file_path, folder_path).replace("\\", "/")
        
        # Remove any existing entries for this file
        try:
            collection.delete(where={"source": file_path})
        except Exception:
            pass  # Ignore errors if document doesn't exist
            
        try:
            # Also try deleting by ID
            collection.delete(ids=[doc_id])
            
            # Try to find chunked IDs
            for i in range(1, 100):  # Reasonable upper limit for chunks
                chunk_id = f"{doc_id}_chunk_{i}"
                try:
                    collection.delete(ids=[chunk_id])
                except:
                    break  # Stop if no more chunks found
        except Exception:
            pass  # Ignore errors if document doesn't exist

if __name__ == "__main__":
    command = sys.argv[1]
    
    if command == "process":
        folder_path = sys.argv[2]
        extensions = sys.argv[3].split(',')
        output_folder = sys.argv[4]
        model_name = sys.argv[5]
        api_url = sys.argv[6]
        chunk_size = int(sys.argv[7])
        
        process_files(folder_path, extensions, output_folder, model_name, api_url, chunk_size)
    elif command == "watch_event":
        event_type = sys.argv[2]  # created, changed, or deleted
        file_path = sys.argv[3]
        folder_path = sys.argv[4]
        extensions = sys.argv[5].split(',')
        output_folder = sys.argv[6]
        model_name = sys.argv[7]
        api_url = sys.argv[8]
        chunk_size = int(sys.argv[9])
        
        handle_file_event(file_path, folder_path, extensions, output_folder, model_name, api_url, chunk_size, event_type)
"@

$pythonCode | Out-File -FilePath $tempPythonScript -Encoding utf8

Write-Host "Starting to build ChromaDB with text file embeddings using Ollama..." -ForegroundColor Cyan
Write-Host "Folder path: $FolderPath" -ForegroundColor Cyan
Write-Host "File extensions: $Extensions" -ForegroundColor Cyan
Write-Host "Output folder: $OutputFolder" -ForegroundColor Cyan
Write-Host "Ollama URL: $OllamaUrl" -ForegroundColor Cyan
Write-Host "Embedding model: $EmbeddingModel" -ForegroundColor Cyan
Write-Host "Chunk size: $ChunkSize characters" -ForegroundColor Cyan
if ($WatchMode) {
    Write-Host "Watch mode: Enabled" -ForegroundColor Cyan
}

# Create the output directory if it doesn't exist
if (-not (Test-Path -Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory | Out-Null
    Write-Host "Created output directory: $OutputFolder" -ForegroundColor Green
}

# Initial processing of all files
$extensionList = $Extensions.Replace(' ', '')
$results = python $tempPythonScript "process" $FolderPath $extensionList $OutputFolder $EmbeddingModel $OllamaUrl $ChunkSize 2>&1

# Process the output
$errors = 0
$processed = 0

foreach ($line in $results) {
    if ($line -match "^STATUS:([^:]+):(.*)$") {
        $statusType = $Matches[1]
        $statusData = $Matches[2]
        
        switch ($statusType) {
            "INFO" {
                Write-Host $statusData -ForegroundColor Cyan
            }
            "PROGRESS" {
                $progressParts = $statusData -split ":"
                if ($progressParts.Count -ge 4) {
                    $current = $progressParts[0]
                    $total = $progressParts[1]
                    $percentage = $progressParts[2]
                    $file = $progressParts[3]
                    
                    $progressText = "Processing: $current/$total - $percentage% - $file"
                    Write-Progress -Activity "Generating Embeddings" `
                                -Status $progressText `
                                -PercentComplete $percentage
                    $processed = $current
                }
            }
            "ERROR" {
                Write-Host "Error: $statusData" -ForegroundColor Red
                $errors++
            }
            "COMPLETE" {
                $completeParts = $statusData -split ":"
                if ($completeParts.Count -ge 2) {
                    $successCount = $completeParts[0]
                    $totalCount = $completeParts[1]
                    Write-Host "Completed processing $successCount of $totalCount files." -ForegroundColor Green
                }
            }
            "WATCH" {
                $watchParts = $statusData -split ":", 2
                if ($watchParts.Count -ge 2) {
                    $eventType = $watchParts[0]
                    $file = $watchParts[1]
                    Write-Host "Watch event: $eventType - $file" -ForegroundColor Green
                }
            }
        }
    } else {
        # Handle non-status output
        Write-Host $line -ForegroundColor Gray
    }
}

Write-Progress -Activity "Generating Embeddings" -Completed

# Final summary of initial processing
Write-Host "`nSummary:" -ForegroundColor Cyan
Write-Host "Successfully processed $processed files" -ForegroundColor Green
if ($errors -gt 0) {
    Write-Host "Encountered $errors errors during processing" -ForegroundColor Yellow
}

# If watch mode is enabled, start monitoring for file changes
if ($WatchMode) {
    Write-Host "`nStarting watch mode. Press Ctrl+C to exit." -ForegroundColor Yellow
    
    # Create a FileSystemWatcher object
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $FolderPath
    $watcher.IncludeSubdirectories = $true
    $watcher.EnableRaisingEvents = $true
    
    # Create filters based on extensions
    $extensionArray = $Extensions.Split(',')
    $filterText = "File extensions: $Extensions"
    $watcher.Filter = "*.*"  # We'll filter in the event handlers
    
    # Define event handlers
    $onChanged = {
        $path = $Event.SourceEventArgs.FullPath
        $name = $Event.SourceEventArgs.Name
        $changeType = $Event.SourceEventArgs.ChangeType
        
        # Check if the extension matches
        $matchesExtension = $false
        foreach ($ext in $extensionArray) {
            if ($path.ToLower().EndsWith($ext.ToLower())) {
                $matchesExtension = $true
                break
            }
        }
        
        if ($matchesExtension) {
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Write-Host "[$timestamp] $changeType detected on: $path" -ForegroundColor Yellow
            
            # Call Python to process the single file
            $eventType = $changeType.ToString().ToLower()
            if ($eventType -eq "renamed") {
                # Treat rename as a deletion of the old file and creation of a new file
                $eventType = "changed"
            }
            
            $pythonArgs = @(
                "watch_event",
                $eventType,
                $path,
                $using:FolderPath,
                $using:extensionList,
                $using:OutputFolder,
                $using:EmbeddingModel,
                $using:OllamaUrl,
                $using:ChunkSize
            )
            
            $updateResult = python $using:tempPythonScript $pythonArgs 2>&1
            
            foreach ($line in $updateResult) {
                if ($line -match "^STATUS:([^:]+):(.*)$") {
                    $statusType = $Matches[1]
                    $statusData = $Matches[2]
                    
                    switch ($statusType) {
                        "ERROR" {
                            Write-Host "Error: $statusData" -ForegroundColor Red
                        }
                        "WATCH" {
                            $watchParts = $statusData -split ":", 2
                            if ($watchParts.Count -ge 2) {
                                $eventType = $watchParts[0]
                                $file = $watchParts[1]
                                Write-Host "Updated ChromaDB: $eventType - $file" -ForegroundColor Green
                            }
                        }
                    }
                } else {
                    # Handle non-status output
                    Write-Host $line -ForegroundColor Gray
                }
            }
        }
    }
    
    # Register event handlers
    $handlers = . {
        Register-ObjectEvent -InputObject $watcher -EventName Changed -Action $onChanged
        Register-ObjectEvent -InputObject $watcher -EventName Created -Action $onChanged
        Register-ObjectEvent -InputObject $watcher -EventName Deleted -Action $onChanged
        Register-ObjectEvent -InputObject $watcher -EventName Renamed -Action $onChanged
    }
    
    Write-Host "Watching for changes in $FolderPath" -ForegroundColor Cyan
    Write-Host $filterText -ForegroundColor Cyan
    Write-Host "ChromaDB will be updated automatically when files are changed" -ForegroundColor Cyan
    Write-Host "Press Ctrl+C to stop watching and exit" -ForegroundColor Yellow
    
    try {
        # Keep the script running until Ctrl+C is pressed
        while ($true) {
            Wait-Event -Timeout 1
            # Optional: Show some indication that the script is still running
            # Write-Host "." -NoNewline -ForegroundColor DarkGray
        }
    }
    finally {
        # Clean up when the script is stopped
        Get-EventSubscriber | Unregister-Event
        $handlers | Remove-Job -Force
        $watcher.Dispose()
        
        Write-Host "`nWatch mode stopped" -ForegroundColor Yellow
    }
}
else {
    Write-Host "`nChromaDB has been created at: $OutputFolder" -ForegroundColor Green
    Write-Host "You can use this database with various retrieval tools and RAG applications." -ForegroundColor Cyan
    Write-Host "To query the database, use the ChromaDB Python API or compatible tools." -ForegroundColor Cyan
    Write-Host "`nTo enable watch mode and automatically update the database when files change, run with -WatchMode" -ForegroundColor Yellow
    Write-Host "Example: .\CreateChromaEmbeddings.ps1 -FolderPath '$FolderPath' -WatchMode" -ForegroundColor Yellow
}

# Clean up
Remove-Item -Path $tempPythonScript -Force
