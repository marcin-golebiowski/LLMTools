# Directory Watcher Script
# This script monitors a specified directory for file changes and sends events to a REST API endpoint

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

    [Parameter(Mandatory = $false)]
    [switch]$ProcessExistingFiles = $false,
    
    [Parameter(Mandatory = $false)]
    [string]$LogPath = "",

    [Parameter(Mandatory = $false)]
    [int]$DedupIntervalSeconds = 15,
    
    [Parameter(Mandatory = $false)]
    [string]$EventName = "LLMTools.FileWatcher",

    [Parameter(Mandatory = $false)]
    [string]$ApiEndpoint = "http://localhost:8080/",
    
    [Parameter(Mandatory = $false)]
    [int]$ApiTimeoutSeconds = 10
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

# Function to send file events to REST API
function Send-FileEvent {
    param (
        [string]$FilePath,
        [string]$ChangeType,
        [string]$ApiEndpoint,
        [int]$ApiTimeoutSeconds
    )
    
    try {
        # Prepare the request body
        $body = @{
            FilePath = $FilePath
            ChangeType = $ChangeType
        } | ConvertTo-Json
        
        # Set headers
        $headers = @{
            "Content-Type" = "application/json"
        }
        
        # Make the request
        $url = $ApiEndpoint + "/api/file"
        Write-Log "$url" -Level "DEBUG"
        $response = Invoke-RestMethod -Uri $url -Method Post -Body $body -Headers $headers -TimeoutSec $ApiTimeoutSeconds -ErrorAction Stop
        
        # Log the response
        Write-Log "API Response: $($response | ConvertTo-Json -Compress)" -Level "DEBUG"
        
        return $true
    }
    catch {
        Write-Log "Error sending file event to API: $_" -Level "ERROR"
        return $false
    }
}

function Send-HealthCheck  {
    try {
        # Set headers
        $headers = @{
            "Content-Type" = "application/json"
        }
        
        # Make the request
        $response = Invoke-RestMethod -Uri ($ApiEndpoint + "/api/health") -Method Get -Headers $headers -TimeoutSec $ApiTimeoutSeconds -ErrorAction Stop
        
        # Log the response
        Write-Log "API Response: $($response | ConvertTo-Json -Compress)" -Level "DEBUG"
        
        return $true
    }
    catch {
        Write-Log "Error sending heath check to API: $_" -Level "ERROR"
        return $false
    }
}

# Test API connection
Write-Log "Testing API connection to $ApiEndpoint..."
try {
    $testResult = Send-HealthCheck 
    if ($testResult) {
        Write-Log "API connection successful" -Level "INFO"
    }
    else {
        Write-Log "API connection failed." -Level "ERROR"
        exit(1)
    }
}
catch {
    Write-Log "API connection test failed: $_" -Level "ERROR"
    Write-Log "Events will be logged but not sent to API." -Level "WARNING"
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
            
            # Send file to API
            $result = Send-FileEvent -FilePath $filePath -ChangeType "Initial" -ApiEndpoint $ApiEndpoint -ApiTimeoutSeconds $ApiTimeoutSeconds
            
            # Also send PowerShell event for backward compatibility
            $fileEventData = @{
                FilePath   = $filePath
                ChangeType = "Initial"
            }
            $eventParams = @{
                SourceIdentifier = $EventName
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
        $eventName = $Event.MessageData.EventName
        $apiEndpoint = $Event.MessageData.ApiEndpoint
        $apiTimeout = $Event.MessageData.ApiTimeoutSeconds
        $sendEvent = $Event.MessageData.SendEvent
        $sendEvent = $Event.MessageData.SendEvent

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
                SourceIdentifier = $eventName
                MessageData      = $fileEventData
                Sender           = $PID
            }
            New-Event @eventParams
            Write-Host "Published event $eventName : $eventKey"
            
            $result = & $sendEvent -FilePath $path -ChangeType $changeType -ApiEndpoint $apiEndpoint -ApiTimeoutSeconds $apiTimeout
            if ($result) {
                Write-Host "Sent to API: $eventKey"
            }
            else {
                Write-Host "Failed to send to API: $eventKey"
            }
            $events[$eventKey] = Get-Date
        }
        else {
            Write-Host "Duplicate event detected: $eventKey"
        }
    }
    catch {
        Write-Host "Error in event handler: $_"
    }
}

$data = @{
    RecentEvents = $recentEvents
    DedupIntervalSeconds = $DedupIntervalSeconds
    EventName = $EventName
    ApiEndpoint = $ApiEndpoint
    ApiTimeoutSeconds = $ApiTimeoutSeconds
    SendEvent = ${function:Send-FileEvent}
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
    Write-Log "Events will be sent to API endpoint: $ApiEndpoint"
    
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
