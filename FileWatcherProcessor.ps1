# FileWatcherProcessor.ps1
# This script listens to events, queues them, and processes them in parallel

param (
    [Parameter(Mandatory = $false)]
    [int]$MaxConcurrentJobs = 4,
    
    [Parameter(Mandatory = $true)]
    [string]$ScriptToExecute,
    
    [Parameter(Mandatory = $false)]
    [string]$LogPath = "",
    
    [Parameter(Mandatory = $false)]
    [int]$QueueCheckIntervalMs = 500,
    
    [Parameter(Mandatory = $false)]
    [switch]$UseJobs = $true,
    
    [Parameter(Mandatory = $false)]
    [string]$EventSourceIdentifier = "LLMTools.FileWatcher"
)

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

# Verify script to execute exists
if (-not (Test-Path -Path $ScriptToExecute)) {
    Write-Log "Script '$ScriptToExecute' does not exist." -Level "ERROR"
    exit 1
}

# Initialize event queue
$eventQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[hashtable]
$activeJobs = @{}

# Register for events
$eventSubscriber = Register-ObjectEvent -InputObject ([System.Management.Automation.PowerShell]::Create()) -EventName InvokeComplete -SourceIdentifier $EventSourceIdentifier -Action {
    # Add event to queue
    $eventData = $Event.MessageData
    $global:eventQueue.Enqueue($eventData)
    Write-Log "Event queued: $($eventData.ChangeType) - $($eventData.FilePath)" -Level "DEBUG"
}

Write-Log "Started listening for $EventSourceIdentifier events."
Write-Log "Processing with maximum $MaxConcurrentJobs concurrent jobs."
Write-Log "Using script: $ScriptToExecute"
if ($UseJobs) {
    Write-Log "Using PowerShell background jobs for parallelism."
} else {
    Write-Log "Using separate processes for parallelism."
}

try {
    while ($true) {
        # Clean up completed jobs
        $jobsToRemove = @()
        foreach ($jobId in $activeJobs.Keys) {
            $job = $activeJobs[$jobId]
            
            if ($UseJobs -and $job.State -ne "Running") {
                # For PowerShell jobs
                $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
                Remove-Job -Job $job -Force
                $jobsToRemove += $jobId
                Write-Log "Job $jobId completed: $result" -Level "INFO"
            } 
            elseif (-not $UseJobs -and $job.HasExited) {
                # For processes
                $jobsToRemove += $jobId
                Write-Log "Process $jobId completed with exit code: $($job.ExitCode)" -Level "INFO"
            }
        }
        
        foreach ($jobId in $jobsToRemove) {
            $activeJobs.Remove($jobId)
        }
        
        # Process queue if we have capacity
        while ($activeJobs.Count -lt $MaxConcurrentJobs -and -not $eventQueue.IsEmpty) {
            $eventData = $null
            $dequeued = $eventQueue.TryDequeue([ref]$eventData)
            
            if ($dequeued -and $eventData -ne $null) {
                Write-Log "Processing event: $($eventData.ChangeType) - $($eventData.FilePath)" -Level "INFO"
                
                # Store event data in temp JSON file to pass to script
                $tempFile = [System.IO.Path]::GetTempFileName()
                $eventData | ConvertTo-Json | Set-Content -Path $tempFile
                
                if ($UseJobs) {
                    # Start a PowerShell background job
                    $job = Start-Job -ScriptBlock {
                        param($scriptPath, $dataPath)
                        & $scriptPath -EventDataPath $dataPath
                    } -ArgumentList $ScriptToExecute, $tempFile
                    
                    $activeJobs[$job.Id] = $job
                    Write-Log "Started job $($job.Id) for file: $($eventData.FilePath)" -Level "INFO"
                } 
                else {
                    # Start a separate process
                    $process = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptToExecute`" -EventDataPath `"$tempFile`"" -PassThru
                    
                    $activeJobs[$process.Id] = $process
                    Write-Log "Started process $($process.Id) for file: $($eventData.FilePath)" -Level "INFO"
                }
            }
        }
        
        # Display status
        Write-Log "Status: Queue depth: $($eventQueue.Count), Active jobs: $($activeJobs.Count)/$MaxConcurrentJobs" -Level "DEBUG"
        
        # Sleep briefly to prevent CPU spinning
        Start-Sleep -Milliseconds $QueueCheckIntervalMs
    }
}
finally {
    # Clean up event subscription and jobs
    Unregister-Event -SourceIdentifier $EventSourceIdentifier -ErrorAction SilentlyContinue
    
    if ($UseJobs) {
        $activeJobs.Values | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    else {
        $activeJobs.Values | ForEach-Object { 
            if (-not $_.HasExited) {
                $_ | Stop-Process -Force -ErrorAction SilentlyContinue
            }
        }
    }
    
    Write-Log "Event processor stopped." -Level "INFO"
}
