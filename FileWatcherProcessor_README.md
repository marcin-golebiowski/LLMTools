# File Watcher Event Processor

This solution provides a PowerShell-based system for processing file system events in a parallel, queue-based architecture.

## Components

The solution consists of two main scripts:

1. **FileWatcherProcessor.ps1** - Listens for events (default: "LLMTools.FileWatcher"), queues them, and executes a custom script in parallel threads (either via PowerShell jobs or separate processes).
2. **FileEventHandler.ps1** - A sample script that demonstrates how to process the file events.

## How It Works

1. The existing `FileWatcher.ps1` script monitors directories for file changes and raises `New-Event` with a specific source identifier (default: "LLMTools.FileWatcher")
2. `FileWatcherProcessor.ps1` subscribes to these events, queues them, and processes them in parallel
3. For each event, `FileWatcherProcessor.ps1` calls your custom script (e.g., `FileEventHandler.ps1`) with the event data
4. The custom script processes the file and returns a result

## Usage

### Step 1: Start the File Watcher

First, run the existing `FileWatcher.ps1` script to monitor a directory:

```powershell
.\FileWatcher.ps1 -DirectoryToWatch "C:\Path\To\Watch" -FileFilter "*.txt" -WatchCreated -WatchModified -IncludeSubdirectories
```

### Step 2: Start the Event Processor

Then, in a separate PowerShell window, run the `FileWatcherProcessor.ps1` script to process the events:

```powershell
.\FileWatcherProcessor.ps1 -ScriptToExecute ".\FileEventHandler.ps1" -MaxConcurrentJobs 4 -LogPath "processor.log"
```

### Parameters for FileWatcherProcessor.ps1

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-MaxConcurrentJobs` | Maximum number of concurrent jobs/processes | 4 |
| `-ScriptToExecute` | Path to the script that will process file events | (Required) |
| `-LogPath` | Path to log file (optional) | "" (logs to console only) |
| `-QueueCheckIntervalMs` | Milliseconds between queue check cycles | 500 |
| `-UseJobs` | Use PowerShell jobs instead of separate processes | True |
| `-EventSourceIdentifier` | The event source identifier to listen for | "LLMTools.FileWatcher" |

### Custom Event Handler Script

The script specified by `-ScriptToExecute` must accept an `-EventDataPath` parameter that points to a temporary JSON file containing the event data. The event data includes:

- `FilePath`: Full path to the affected file
- `ChangeType`: Type of change (Created, Modified, Deleted, Renamed, etc.)

Example structure of a custom handler script:

```powershell
param (
    [Parameter(Mandatory = $true)]
    [string]$EventDataPath
)

# Load event data
$eventData = Get-Content -Path $EventDataPath -Raw | ConvertFrom-Json

# Process the file
$filePath = $eventData.FilePath
$changeType = $eventData.ChangeType

# Your custom processing logic here
Write-Host "Processing $changeType event for $filePath"

# Clean up
Remove-Item -Path $EventDataPath -Force

# Return a result (captured when using jobs)
return "Processed $filePath"
```

## Examples

### Basic Usage

```powershell
# Terminal 1: Start file watcher
.\FileWatcher.ps1 -DirectoryToWatch "C:\Data" -WatchCreated -WatchModified -ProcessExistingFiles

# Terminal 2: Start event processor 
.\FileWatcherProcessor.ps1 -ScriptToExecute ".\FileEventHandler.ps1" -MaxConcurrentJobs 2
```

### High-Performance Configuration

For high-volume file processing with detailed logging:

```powershell
.\FileWatcherProcessor.ps1 -ScriptToExecute ".\FileEventHandler.ps1" -MaxConcurrentJobs 8 -UseJobs $false -QueueCheckIntervalMs 100 -LogPath "high_volume_processing.log"
```

## Notes

- Using `-UseJobs $true` (default) leverages PowerShell background jobs, which are easier to manage but have more overhead
- Using `-UseJobs $false` starts separate PowerShell processes, which may be more efficient for CPU-intensive tasks
- The event queue is managed in memory, so events will be lost if the processor script is terminated
- You can start multiple processors with different handler scripts to process the same events in different ways
