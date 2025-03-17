# FileWatcher System

This system consists of two PowerShell scripts working together to monitor file changes and process them:

1. **FileWatcher.ps1**: Monitors specified directories for file changes and sends events to the REST API.
2. **FileWatcherConsumer.ps1**: Provides a REST API server that receives file events, maintains a queue, and processes them with a custom script.

## Major Changes

- Replaced named pipe communication with REST API for better reliability and more features
- Added file event queue management through API endpoints
- Added proper handling for Ctrl+C, Ctrl+D, and Ctrl+Z signals
- Improved error handling and resource cleanup

## FileWatcherConsumer.ps1

### Overview

The consumer script starts a REST API server that:
- Receives file events through HTTP requests
- Maintains a queue of pending file events
- Processes events by executing a provided script
- Provides endpoints to monitor and manage the queue

### Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-Port` | The port to run the REST API server on | 8080 |
| `-MaxConcurrentJobs` | Maximum number of concurrent processing jobs | 4 |
| `-ScriptToExecute` | Path to the script that will process file events (**required**) | - |
| `-LogPath` | Path to write log messages to | "log.txt" |
| `-QueueCheckIntervalMs` | Milliseconds between queue processing attempts | 500 |
| `-UseJobs` | Switch to use PowerShell jobs instead of separate processes | false |

### API Endpoints

#### POST /api/file
Add a file event to the processing queue.

**Example request:**
```json
{
  "FilePath": "C:\\path\\to\\file.txt",
  "ChangeType": "Modified"
}
```

**Response:**
```json
{
  "success": true,
  "message": "File event added to queue",
  "event": {
    "ChangeType": "Modified",
    "FilePath": "C:\\path\\to\\file.txt",
    "Timestamp": "2025-03-17T18:30:00"
  }
}
```

#### GET /api/queue
Get the current queue status and contents.

**Response:**
```json
{
  "success": true,
  "queueDepth": 3,
  "activeJobs": 2,
  "maxConcurrentJobs": 4,
  "queue": [
    {
      "ChangeType": "Created",
      "FilePath": "C:\\path\\to\\file1.txt",
      "Timestamp": "2025-03-17T18:25:00"
    },
    {
      "ChangeType": "Modified",
      "FilePath": "C:\\path\\to\\file2.txt",
      "Timestamp": "2025-03-17T18:26:00"
    },
    {
      "ChangeType": "Modified",
      "FilePath": "C:\\path\\to\\file3.txt",
      "Timestamp": "2025-03-17T18:27:00"
    }
  ]
}
```

#### DELETE /api/queue
Clear the current queue of pending file events.

**Response:**
```json
{
  "success": true,
  "message": "Queue cleared",
  "removedCount": 3
}
```

#### GET /api/status
Get the current status of the service.

**Response:**
```json
{
  "success": true,
  "status": "running",
  "queueDepth": 3,
  "activeJobs": 2,
  "maxConcurrentJobs": 4,
  "scriptToExecute": "D:\\LLMTools\\LLMTools\\FileEventHandler.ps1",
  "useJobs": false
}
```

## FileWatcher.ps1

### Overview

The watcher script monitors directories for file system changes and sends events to the REST API server.

### Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-DirectoryToWatch` | Directory to monitor for changes (**required**) | - |
| `-FileFilter` | Filter pattern for files to watch | "*.*" |
| `-WatchCreated` | Switch to watch for file creation events | false |
| `-WatchModified` | Switch to watch for file modification events | false |
| `-WatchDeleted` | Switch to watch for file deletion events | false |
| `-WatchRenamed` | Switch to watch for file renaming events | false |
| `-IncludeSubdirectories` | Switch to monitor subdirectories | false |
| `-ProcessExistingFiles` | Switch to process existing files on startup | false |
| `-LogPath` | Path to write log messages to | "" |
| `-DedupIntervalSeconds` | Seconds to wait before considering duplicate events as new | 15 |
| `-EventName` | Name for PowerShell events (for backward compatibility) | "LLMTools.FileWatcher" |
| `-ApiEndpoint` | URL of the REST API endpoint to send events to | "http://localhost:8080/api/file" |
| `-ApiTimeoutSeconds` | Timeout for API requests in seconds | 10 |

## Usage Examples

### Start the Consumer (REST API server)

```powershell
# Start the consumer with default settings
.\FileWatcherConsumer.ps1 -ScriptToExecute ".\FileEventHandler.ps1"

# Start with custom port and higher concurrency
.\FileWatcherConsumer.ps1 -Port 9000 -MaxConcurrentJobs 8 -ScriptToExecute ".\FileEventHandler.ps1" -UseJobs
```

### Start the File Watcher

```powershell
# Watch a directory for created and modified files
.\FileWatcher.ps1 -DirectoryToWatch "D:\Documents" -WatchCreated -WatchModified -FileFilter "*.docx"

# Watch including subdirectories with custom API endpoint
.\FileWatcher.ps1 -DirectoryToWatch "D:\Projects" -WatchCreated -WatchModified -WatchDeleted -IncludeSubdirectories -ApiEndpoint "http://localhost:9000/api/file"

# Process existing files and watch for new ones
.\FileWatcher.ps1 -DirectoryToWatch "D:\Images" -ProcessExistingFiles -WatchCreated -WatchModified -FileFilter "*.jpg"
```

### Testing with curl

```powershell
# Add a file event to the queue
curl -X POST http://localhost:8080/api/file -H "Content-Type: application/json" -d '{"FilePath":"C:\\test\\file.txt","ChangeType":"Created"}'

# Get the current queue
curl -X GET http://localhost:8080/api/queue

# Clear the queue
curl -X DELETE http://localhost:8080/api/queue

# Check service status
curl -X GET http://localhost:8080/api/status
```

## Implementation Details

### Script Processing

When a file event is processed from the queue, the consumer script:

1. Creates a temporary JSON file with the event data
2. Passes the path to this file to the processing script
3. The processing script should accept a parameter `-EventDataPath` that points to this JSON file
4. The JSON file contains the file path and change type

Example processing script:

```powershell
param (
    [Parameter(Mandatory = $true)]
    [string]$EventDataPath
)

# Load the event data
$eventData = Get-Content -Path $EventDataPath | ConvertFrom-Json

# Process the file
$filePath = $eventData.FilePath
$changeType = $eventData.ChangeType

Write-Host "Processing $changeType event for $filePath"

# Your processing logic here...
```

## Termination

Both scripts properly handle termination signals (Ctrl+C, Ctrl+D, Ctrl+Z) and clean up resources. The consumer will stop the REST API server, clean up any running jobs, and release all resources when terminated.
