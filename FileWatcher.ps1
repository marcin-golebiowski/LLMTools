# Directory Watcher Script
# This script monitors a specified directory for file changes and calls the upload script when files are created or modified

param (
    [Parameter(Mandatory = $true)]
    [string]$DirectoryToWatch,
    
    [Parameter(Mandatory = $false)]
    [string]$FileFilter = "*.*",

    [Parameter(Mandatory = $false)]
    [switch]$WatchCreated = $false,
    
    [Parameter(Mandatory = $false)]
    [switch]$WatchModified = $false,
    
    [Parameter(Mandatory = $false)]
    [switch]$WatchDeleted = $false,
    
    [Parameter(Mandatory = $false)]
    [switch]$WatchRenamed = $false,
    
    [Parameter(Mandatory = $false)]
    [switch]$IncludeSubdirectories = $false,

    [Parameter(Mandatory = $true)]
    [switch]$ProcessExistingFiles = $false,
    
    [Parameter(Mandatory = $false)]
    [string]$LogPath = "",

    [Parameter(Mandatory = $false)]
    [int]$DedupIntervalSeconds = 15
)

# Ensure the directory exists
if (-not (Test-Path -Path $DirectoryToWatch)) {
    Write-Error "Directory $DirectoryToWatch does not exist."
    exit 1
}

# Setup logging
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    Write-Host $logMessage
    
    if ($LogPath -ne "") {
        Add-Content -Path $LogPath -Value $logMessage
    }
}

Write-Log "Starting directory watcher for $DirectoryToWatch"
Write-Log "Watching for file changes matching $FileFilter"

# Process existing files in the directory (initial state)
if ($ProcessExistingFiles) {
    Write-Log "Processing existing files in the directory..."
    $existingFiles = Get-ChildItem -Path $DirectoryToWatch -Filter $FileFilter -Recurse:$IncludeSubdirectories
    $totalFiles = $existingFiles.Count
    
    if ($totalFiles -eq 0) {
        Write-Log "No existing files found matching filter: $FileFilter"
    }
    else {
        Write-Log "Found $totalFiles files to process..."
        
        # Setup progress bar
        $progressParams = @{
            Activity        = "Processing existing files"
            Status          = "0% Complete"
            PercentComplete = 0
        }
        Write-Progress @progressParams
        
        # Process each file
        for ($i = 0; $i -lt $totalFiles; $i++) {
            $file = $existingFiles[$i]
            $filePath = $file.FullName
            $percentComplete = [math]::Round(($i / $totalFiles) * 100)
            
            # Update progress bar
            $progressParams.Status = "Processing $($i+1) of $totalFiles ($percentComplete% Complete)"
            $progressParams.PercentComplete = $percentComplete
            $progressParams.CurrentOperation = "Processing: $($file.Name)"
            Write-Progress @progressParams
            
            Write-Log "[$($i+1)/$totalFiles] Processing existing file: $($file.Name)"
            
            # Upload each existing file
            $fileEventData = @{
                FilePath   = $filePath
                ChangeType = "Added-Existing"
            }
           
            # Process 2: Send an event
            $eventParams = @{
                SourceIdentifier = "LLMTools.FileWatcher"
                MessageData      = $fileEventData
                Sender           = $PID
            }
            New-Event @eventParams
        }
        
        # Complete progress bar
        Write-Progress -Activity "Processing existing files" -Completed
        
        Write-Log "Initial state processing complete. Processed $totalFiles files."
    }
}

Write-Log "Now watching for new changes..."
Write-Log "Press Ctrl+C to stop the watcher."

# Create a FileSystemWatcher to monitor the directory
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $DirectoryToWatch
$watcher.Filter = $FileFilter
$watcher.IncludeSubdirectories = $IncludeSubdirectories
$watcher.EnableRaisingEvents = $true

# Collection to store event handlers
$eventHandlers = @()
$recentEvents = @{}

$scriptBlock = {
    try {
        $path = $Event.SourceEventArgs.FullPath
        $changeType = $Event.SourceEventArgs.ChangeType
        $events = $Event.MessageData.RecentEvents
        $interval = $Event.MessageData.DedupIntervalSeconds

        $fileEventData = @{
            FilePath   = $path
            ChangeType = $changeType
        }

        $eventKey = "$($fileEventData.ChangeType)|$($fileEventData.FilePath)"
        $isDuplicate = $false
        if ($events.ContainsKey($eventKey)) {
            $lastTime = $events[$eventKey]
            $timeDiff = (Get-Date) - $lastTime
            if ($timeDiff.TotalSeconds -lt $interval) {
                $isDuplicate = $true
            }
        }

        if ($isDuplicate -eq $false) {
            $eventParams = @{
                SourceIdentifier = "LLMTools.FileWatcher"
                MessageData      = $fileEventData
                Sender           = $PID
            }

            New-Event @eventParams
            Write-Host $eventKey
            $events[$eventKey] = Get-Date
        }
        else {
            Write-Host "Duplicate event detected: $eventKey"
        }
    }
    catch {
        Write-Host "Error: $_"
    }
}

$data = @{
    RecentEvents = $recentEvents
    DedupIntervalSeconds = $DedupIntervalSeconds
}

if ($WatchCreated) {
    $onCreated = Register-ObjectEvent -InputObject $watcher -EventName Created -Action $scriptBlock -MessageData $data
    $eventHandlers += $onCreated
}

if ($WatchModified) {
    $onChanged = Register-ObjectEvent -InputObject $watcher -EventName Changed -Action $scriptBlock -MessageData $data
    $eventHandlers += $onChanged
}

if ($WatchDeleted) {
    $onDeleted = Register-ObjectEvent -InputObject $watcher -EventName Deleted -Action $scriptBlock -MessageData $data
    $eventHandlers += $onDeleted
}

if ($WatchRenamed) {
    $onRenamed = Register-ObjectEvent -InputObject $watcher -EventName Renamed -Action $scriptBlock -MessageData $data
    $eventHandlers += $onRenamed
}

# Keep the script running until Ctrl+C is pressed
try {
    Write-Log "Watcher started successfully. Waiting for events..."
    
    # Create a summary of what's being watched
    $watchEvents = @()
    if ($WatchCreated) { $watchEvents += "Created" }
    if ($WatchModified) { $watchEvents += "Modified" }
    if ($WatchDeleted) { $watchEvents += "Deleted" }
    if ($WatchRenamed) { $watchEvents += "Renamed" }
    
    Write-Log "Monitoring for events: {$($watchEvents -join ', ')}"
    if ($IncludeSubdirectories) {
        Write-Log "Including subdirectories in watch"
    }
    
    while ($true) { Start-Sleep -Seconds 1 }
} 
finally {
    # Clean up event handlers when the script is stopped
    foreach ($handler in $eventHandlers) {
        Unregister-Event -SourceIdentifier $handler.Name
    }
    $watcher.Dispose()
    Write-Log "Watcher stopped."
}
