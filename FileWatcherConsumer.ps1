# FileWatcherConsumer.ps1
# This script provides a REST API for processing file events using Pode

param (
    [Parameter(Mandatory = $false)]
    [int]$Port = 8080,
    
    [Parameter(Mandatory = $false)]
    [int]$MaxConcurrentJobs = 4,
    
    [Parameter(Mandatory = $true)]
    [string]$ScriptToExecute,
    
    [Parameter(Mandatory = $false)]
    [string]$LogPath = "log.txt",
    
    [Parameter(Mandatory = $false)]
    [int]$QueueCheckIntervalMs = 500,
    
    [Parameter(Mandatory = $false)]
    [switch]$UseJobs = $false
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
}

# Verify script to execute exists
if (-not (Test-Path -Path $ScriptToExecute)) {
    Write-Log "Script '$ScriptToExecute' does not exist." -Level "ERROR"
    exit 1
}

# Check if Pode module is installed, if not try to install it
if (-not (Get-Module -ListAvailable -Name Pode)) {
    Write-Log "Pode module not found. Attempting to install..." -Level "WARN"
    try {
        Install-Module -Name Pode -Force -Scope CurrentUser
        Write-Log "Pode module installed successfully." -Level "INFO"
    }
    catch {
        Write-Log "Failed to install Pode module: $_" -Level "ERROR"
        Write-Log "Please install Pode manually: Install-Module -Name Pode -Force -Scope CurrentUser" -Level "ERROR"
        exit 1
    }
}

# Import the Pode module
Import-Module Pode
Add-Type -AssemblyName System.Collections.Concurrent

# Initialize event queue
$eventQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[hashtable]
$activeJobs = @{}
$shouldExit = $false

# Configure signal handling for graceful shutdown
Write-Log "Queue={$eventQueue}"
Write-Log "Processing with maximum $MaxConcurrentJobs concurrent jobs."
Write-Log "Using script: $ScriptToExecute"
if ($UseJobs) {
    Write-Log "Using PowerShell background jobs for parallelism."
} else {
    Write-Log "Using separate processes for parallelism."
}

# Create and start the Pode server
try {
    # Start server
    Start-PodeServer {
        # Enable error logging
        New-PodeLoggingMethod -Terminal

        # Store the context for graceful shutdown
        $stateWrapper = @{
            'Queue' = $eventQueue
            
        }
        
        Set-PodeState -Name 'State' -Value $stateWrapper -Scope 'Server'

        # Basic server configuration
        Add-PodeEndpoint -Address localhost -Port $Port -Protocol Http
        Add-PodeTimer -Name "MySchedule" -Interval 3 -ScriptBlock {
            Write-Host "Schedule triggered at $(Get-Date)"
            Process-Queue
        }
        
        # POST /api/file - Add a file event to the queue
        Add-PodeRoute -Method Post -Path '/api/file' -ScriptBlock {
            $eventData = $WebEvent.Data
            $state = Get-PodeState -Name 'State'
            $queue = $state.Queue

            if (-not $eventData.FilePath) {
                Write-PodeJsonResponse -Value @{
                        success = $false
                        message = "FilePath is required"
                }
                return
            }
            $fileEvent = @{
                ChangeType = $eventData.ChangeType ?? "Modified"
                FilePath = $eventData.FilePath
            }
            
            $queue.Enqueue($fileEvent) | Out-Null
            Write-Log "Event queued: $($fileEvent.ChangeType) - $($fileEvent.FilePath)" -Level "INFO"
            Write-PodeJsonResponse -Value @{
                success = $true
                message = $fileEvent
            }
        }
        
        # GET /api/queue - Get the current queue status
        Add-PodeRoute -Method Get -Path '/api/queue' -ScriptBlock {
            $state = Get-PodeState -Name 'State'
            Write-PodeJsonResponse -Value @{
                success = $true
                message = "Queue"
                queueDepth = $state.Queue.Count
            }
        }
        
        
        # DELETE /api/queue - Clear the queue
        Add-PodeRoute -Method Delete -Path '/api/queue' -ScriptBlock {
            $state = Get-PodeState -Name 'State'
            $queue = $state.Queue
            $count = $queue.Count
            
            $queue.Clear()
            Write-Log "Queue cleared: $count items removed" -Level "INFO"

            Write-PodeJsonResponse -Value @{
                    success = $true
                    message = "Queue cleared"
                    removedCount = $count
            }
        }
        
        # GET /api/status - Get the current status of the service
        Add-PodeRoute -Method Get -Path '/api/status' -ScriptBlock {
            $state = Get-PodeState -Name 'State'
            $queue = $state.Queue
            Write-PodeJsonResponse -Value @{
                    success = $true
                    status = "running"
                    queueDepth = $queue.Count
            }
        }
        
        
        # GET /api/health - Health check endpoint
        Add-PodeRoute -Method Get -Path '/api/health' -ScriptBlock {
            Write-PodeJsonResponse -Value @{
                success = $true
                message = "Healthy"
            }
        }
        
        # Define cleanup logic for server termination
        Add-PodeTimer -Name 'CleanupTimer' -Interval 1 -ScriptBlock {
            if ($script:shouldExit) {
                Write-Log "Shutting down server..." -Level "INFO"
                Stop-PodeServer
            }
        }
        
        # Register termination handler
        Register-PodeEvent -Type Terminate -Name 'ServerTermination' -ScriptBlock {
            Write-Log "Server terminating, cleaning up resources..." -Level "INFO"
            
            # Clean up any active jobs
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
        }
        
        # Output startup information
        Write-Log "REST API server started at http://localhost:$Port/" -Level "INFO"
    }
}
catch {
    Write-Log "Error starting server: $_" -Level "ERROR"
    exit 1
}
finally {
    Write-Log "Server has been shut down" -Level "INFO"
    
    # Final cleanup
    if ($UseJobs) {
        Get-Job | Where-Object { $activeJobs.ContainsKey($_.Id) } | Remove-Job -Force -ErrorAction SilentlyContinue
    }
}

# Function to process the queue
function Process-Queue {
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
}

# Handle Ctrl+C termination
try {
    while ($true) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if (($key.Modifiers -band [ConsoleModifiers]::Control) -and ($key.Key -eq 'C')) {
                Write-Log "Ctrl+C detected, initiating graceful shutdown..." -Level "INFO"
                $script:shouldExit = $true
                break
            }
        }
        Start-Sleep -Milliseconds 100
    }
}
catch {
    Write-Log "Error in main loop: $_" -Level "ERROR"
}
finally {
    if (-not $script:shouldExit) {
        $script:shouldExit = $true
        Write-Log "Forcing server shutdown..." -Level "INFO"
        if ($null -ne $script:PodeContext) {
            Stop-PodeServer -Force
        }
    }
}
