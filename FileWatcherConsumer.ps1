# FileWatcherConsumer.ps1
# This script provides a REST API for processing file events

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
$script:eventQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[hashtable]
$activeJobs = @{}
$script:shouldExit = $false

# Import required modules
Add-Type -AssemblyName System.Web
[Reflection.Assembly]::LoadWithPartialName("System.Web") | Out-Null

function Start-WebServer {
    param (
        [int]$Port
    )
    
    # Create a listener on the specified port
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Prefixes.Add("http://+:$Port/")
    
    try {
        $listener.Start()
        Write-Log "REST API server started at http://localhost:$Port/" -Level "INFO"
        return $listener
    }
    catch {
        Write-Log "Failed to start REST API server: $_" -Level "ERROR"
        throw
    }
}

function Process-HttpRequest {
    param (
        [System.Net.HttpListenerContext]$context
    )
    
    $request = $context.Request
    $response = $context.Response
    
    # Set CORS headers to allow all origins
    $response.Headers.Add("Access-Control-Allow-Origin", "*")
    $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
    $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type, Authorization")

    # Handle preflight OPTIONS requests
    if ($request.HttpMethod -eq "OPTIONS") {
        $response.StatusCode = 200
        $response.Close()
        return
    }
    
    try {
        $path = $request.Url.LocalPath
        $method = $request.HttpMethod
        
        Write-Log "Received $method request for $path" -Level "DEBUG"
        
        switch -regex ($path) {
            "^/api/file$" {
                if ($method -eq "POST") {
                    # Add a file event to the queue
                    $streamReader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $requestBody = $streamReader.ReadToEnd()
                    $eventData = $requestBody | ConvertFrom-Json
                    
                    if (-not $eventData.FilePath) {
                        Send-Response -Response $response -StatusCode 400 -Body @{
                            success = $false
                            message = "FilePath is required"
                        }
                        return
                    }
                    
                    $fileEvent = @{
                        ChangeType = $eventData.ChangeType ?? "Modified"
                        FilePath = $eventData.FilePath
                        Timestamp = Get-Date
                    }
                    
                    $script:eventQueue.Enqueue($fileEvent)
                    Write-Log "Event queued: $($fileEvent.ChangeType) - $($fileEvent.FilePath)" -Level "INFO"
                    
                    Send-Response -Response $response -StatusCode 200 -Body @{
                        success = $true
                        message = "File event added to queue"
                        event = $fileEvent
                    }
                }
                else {
                    Send-Response -Response $response -StatusCode 405 -Body @{
                        success = $false
                        message = "Method not allowed"
                    }
                }
                break
            }
            
            "^/api/queue$" {
                if ($method -eq "GET") {
                    # Get the current queue status
                    $queueSnapshot = @($script:eventQueue.ToArray())
                    
                    Send-Response -Response $response -StatusCode 200 -Body @{
                        success = $true
                        queueDepth = $queueSnapshot.Count
                        activeJobs = $activeJobs.Count
                        maxConcurrentJobs = $MaxConcurrentJobs
                        queue = $queueSnapshot
                    }
                }
                elseif ($method -eq "DELETE") {
                    # Clear the queue
                    $oldQueue = @($script:eventQueue.ToArray())
                    $count = $oldQueue.Count
                    
                    $newQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[hashtable]
                    $script:eventQueue = $newQueue
                    
                    Write-Log "Queue cleared: $count items removed" -Level "INFO"
                    
                    Send-Response -Response $response -StatusCode 200 -Body @{
                        success = $true
                        message = "Queue cleared"
                        removedCount = $count
                    }
                }
                else {
                    Send-Response -Response $response -StatusCode 405 -Body @{
                        success = $false
                        message = "Method not allowed"
                    }
                }
                break
            }
            
            "^/api/status$" {
                if ($method -eq "GET") {
                    # Get the current status of the service
                    Send-Response -Response $response -StatusCode 200 -Body @{
                        success = $true
                        status = "running"
                        queueDepth = $script:eventQueue.Count
                        activeJobs = $activeJobs.Count
                        maxConcurrentJobs = $MaxConcurrentJobs
                        scriptToExecute = $ScriptToExecute
                        useJobs = $UseJobs
                    }
                }
                else {
                    Send-Response -Response $response -StatusCode 405 -Body @{
                        success = $false
                        message = "Method not allowed"
                    }
                }
                break
            }
            
            default {
                Send-Response -Response $response -StatusCode 404 -Body @{
                    success = $false
                    message = "Endpoint not found"
                }
                break
            }
        }
    }
    catch {
        Write-Log "Error processing request: $_" -Level "ERROR"
        Send-Response -Response $response -StatusCode 500 -Body @{
            success = $false
            message = "Internal server error: $_"
        }
    }
}

function Send-Response {
    param (
        [System.Net.HttpListenerResponse]$Response,
        [int]$StatusCode,
        [object]$Body
    )
    
    $Response.StatusCode = $StatusCode
    $Response.ContentType = "application/json"
    
    $jsonBody = $Body | ConvertTo-Json -Depth 10
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
    
    $Response.ContentLength64 = $buffer.Length
    $Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Response.Close()
}

# Start the web server
$listener = Start-WebServer -Port $Port

Write-Log "Processing with maximum $MaxConcurrentJobs concurrent jobs."
Write-Log "Using script: $ScriptToExecute"
if ($UseJobs) {
    Write-Log "Using PowerShell background jobs for parallelism."
} else {
    Write-Log "Using separate processes for parallelism."
}

try {
    # Main processing loop
    while (-not $script:shouldExit) {
        # Check if Ctrl+D or Ctrl+Z was pressed
        if ($keyHandlerJob.State -eq 'Completed') {
            $keyResult = Receive-Job -Job $keyHandlerJob -ErrorAction SilentlyContinue
            if ($keyResult -eq "EXIT") {
                Write-Log "Ctrl+D or Ctrl+Z detected, initiating graceful shutdown..." -Level "INFO"
                $script:shouldExit = $true
                continue
            }
        }
        
        # Process HTTP requests asynchronously
        if ($listener.IsListening) {
            $contextTask = $listener.GetContextAsync()
            
            while ($contextTask.IsCompleted -eq $false -and $script:shouldExit -eq $false) {
                Start-Sleep -Milliseconds 100
            }
            
            if ($contextTask.IsCompleted -and -not $script:shouldExit) {
                $context = $contextTask.Result
                # Process the request in a separate thread to keep the main loop responsive
                Start-ThreadJob -ScriptBlock {
                    param($ctx, $scriptScope)
                    . $scriptScope Process-HttpRequest -context $ctx
                } -ArgumentList $context, $MyInvocation.MyCommand.ScriptBlock | Out-Null
            }
        }
        
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
    Write-Log "Script terminating, cleaning up resources..." -Level "INFO"
    
    # Stop the HTTP listener
    if ($listener -ne $null) {
        try {
            $listener.Stop()
            $listener.Close()
            Write-Log "REST API server stopped" -Level "INFO"
        }
        catch {
            Write-Log "Error stopping REST API server: $_" -Level "ERROR"
        }
    }
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
    
    # Clean up any thread jobs that were created for HTTP request processing
    Get-Job -Command "Process-HttpRequest" | Remove-Job -Force -ErrorAction SilentlyContinue
}
