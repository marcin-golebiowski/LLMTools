# ApiServer.ps1
# REST API server to monitor and control synchronization operations
# Provides endpoints to check progress, start, and stop synchronization

#Requires -Version 7.0
#Requires -Modules Microsoft.PowerShell.Management, Microsoft.PowerShell.Utility

param (
    [Parameter(Mandatory=$false)]
    [string]$ListenAddress = "localhost",
    
    [Parameter(Mandatory=$false)]
    [int]$Port = 8080,
    
    [Parameter(Mandatory=$false)]
    [switch]$UseHttps
)

# Global state to track running jobs and their status
$Global:SyncJobs = @{}
$Global:ProgressStates = @{}
$Global:JobIdCounter = 0
$Global:SyncLogFile = Join-Path -Path $PSScriptRoot -ChildPath "sync-api.log"

# Set up logging
function Write-ApiLog {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Write to console
    if ($Level -eq "ERROR") {
        Write-Host $logMessage -ForegroundColor Red
    }
    elseif ($Level -eq "WARNING") {
        Write-Host $logMessage -ForegroundColor Yellow
    }
    else {
        Write-Host $logMessage -ForegroundColor Cyan
    }
    
    # Ensure log directory exists
    $logDir = Split-Path -Path $Global:SyncLogFile -Parent
    if (-not (Test-Path -Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    
    # Write to log file
    Add-Content -Path $Global:SyncLogFile -Value $logMessage
}

# Function to generate a unique job ID
function New-JobId {
    $Global:JobIdCounter++
    return "job-$($Global:JobIdCounter)-$(Get-Random)"
}

# Function to get PDF-to-Markdown synchronization status
function Get-PdfToMarkdownStatus {
    param (
        [Parameter(Mandatory=$true)]
        [string]$JobId
    )
    
    $status = @{
        jobId = $JobId
        state = "unknown"
        details = ""
        progress = 0
        startTime = $null
        runtime = $null
    }
    
    # Check if job exists
    if ($Global:SyncJobs.ContainsKey($JobId)) {
        $job = $Global:SyncJobs[$JobId]
        $progressState = $Global:ProgressStates[$JobId]
        
        # Update status from job
        $status.startTime = $progressState.startTime.ToString("o")
        $runtime = (Get-Date) - $progressState.startTime
        $status.runtime = [math]::Round($runtime.TotalSeconds)
        
        # Check job state
        if ($job.State -eq "Running") {
            $status.state = "running"
            $status.progress = $progressState.progress
            $status.details = $progressState.details
        }
        elseif ($job.State -eq "Completed") {
            $status.state = "completed"
            $status.progress = 100
            $status.details = "PDF conversion completed successfully"
        }
        elseif ($job.State -eq "Failed" -or $job.State -eq "Stopped") {
            $status.state = "failed"
            $status.details = $progressState.details
        }
        else {
            $status.state = $job.State.ToLower()
        }
    }
    
    return $status
}

# Function to get Chroma embedding synchronization status
function Get-ChromaEmbeddingStatus {
    param (
        [Parameter(Mandatory=$true)]
        [string]$JobId
    )
    
    $status = @{
        jobId = $JobId
        state = "unknown"
        details = ""
        progress = 0
        processed = 0
        totalFiles = 0
        startTime = $null
        runtime = $null
    }
    
    # Check if job exists
    if ($Global:SyncJobs.ContainsKey($JobId)) {
        $job = $Global:SyncJobs[$JobId]
        $progressState = $Global:ProgressStates[$JobId]
        
        # Update status from job
        $status.startTime = $progressState.startTime.ToString("o")
        $runtime = (Get-Date) - $progressState.startTime
        $status.runtime = [math]::Round($runtime.TotalSeconds)
        $status.processed = $progressState.processed
        $status.totalFiles = $progressState.totalFiles
        
        # Check job state
        if ($job.State -eq "Running") {
            $status.state = "running"
            $status.progress = $progressState.progress
            $status.details = $progressState.details
        }
        elseif ($job.State -eq "Completed") {
            $status.state = "completed"
            $status.progress = 100
            $status.details = "Embedding generation completed successfully"
        }
        elseif ($job.State -eq "Failed" -or $job.State -eq "Stopped") {
            $status.state = "failed"
            $status.details = $progressState.details
        }
        else {
            $status.state = $job.State.ToLower()
        }
    }
    
    return $status
}

# Function to start PDF-to-Markdown synchronization
function Start-PdfToMarkdownSync {
    param (
        [Parameter(Mandatory=$true)]
        [string]$SourceDirectory,
        
        [Parameter(Mandatory=$true)]
        [string]$OutputDirectory,
        
        [Parameter(Mandatory=$false)]
        [switch]$WatchMode,
        
        [Parameter(Mandatory=$false)]
        [int]$PollingInterval = 30,
        
        [Parameter(Mandatory=$false)]
        [switch]$RemoveOriginals,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("marker", "tesseract", "ocrmypdf", "pymupdf")]
        [string]$OcrTool = "marker"
    )
    
    # Create a unique job ID
    $jobId = New-JobId
    
    # Initialize progress state
    $Global:ProgressStates[$jobId] = @{
        startTime = Get-Date
        progress = 0
        details = "Initializing PDF to Markdown conversion"
    }
    
    # Create script block for background job
    $scriptBlock = {
        param(
            $ScriptPath,
            $SourceDirectory,
            $OutputDirectory,
            $WatchMode,
            $PollingInterval,
            $RemoveOriginals,
            $OcrTool,
            $JobId,
            $LogFile
        )
        
        # Function to update progress
        function Update-Progress {
            param (
                [int]$Progress,
                [string]$Details
            )
            
            # Create a temporary file with the progress info
            $progressFile = Join-Path -Path $env:TEMP -ChildPath "pdf2md_progress_$JobId.json"
            $progressObj = @{
                jobId = $JobId
                progress = $Progress
                details = $Details
                timestamp = (Get-Date).ToString("o")
            }
            
            $progressObj | ConvertTo-Json | Out-File -FilePath $progressFile -Force
        }
        
        try {
            # Set up event handling for log file monitoring to track progress
            $logPath = $OutputDirectory
            $logFile = Join-Path -Path $logPath -ChildPath "pdf-processor.log"
            
            # Initialize fsWatcher to monitor the log file
            $fsWatcher = New-Object System.IO.FileSystemWatcher
            $fsWatcher.Path = $logPath
            $fsWatcher.Filter = "pdf-processor.log"
            $fsWatcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite
            $fsWatcher.EnableRaisingEvents = $true
            
            # Set up an event handler for the log file changes
            Register-ObjectEvent -InputObject $fsWatcher -EventName Changed -Action {
                $logFile = $Event.SourceEventArgs.FullPath
                $content = Get-Content -Path $logFile -Tail 10
                
                # Look for progress information in the log
                foreach ($line in $content) {
                    # Example log line: [2023-01-01 12:00:00] [INFO] Processing complete. Processed 42 files.
                    if ($line -match "Processing complete\. Processed (\d+) files") {
                        $processed = $matches[1]
                        Update-Progress -Progress 100 -Details "Completed processing $processed files"
                    }
                    # Look for specific file processing logs to estimate progress
                    elseif ($line -match "Converting (.*) to Markdown") {
                        $file = $matches[1]
                        # We don't know the total here, so provide a message
                        Update-Progress -Progress 50 -Details "Processing file: $file"
                    }
                }
            } | Out-Null
            
            # Build command arguments based on provided parameters
            $cmdArgs = @(
                "-File", $ScriptPath,
                "-SourceDirectory", $SourceDirectory,
                "-OutputDirectory", $OutputDirectory,
                "-OcrTool", $OcrTool
            )
            
            if ($WatchMode) {
                $cmdArgs += "-WatchMode"
                $cmdArgs += "-PollingInterval"
                $cmdArgs += $PollingInterval
            }
            
            if ($RemoveOriginals) {
                $cmdArgs += "-RemoveOriginals"
            }
            
            # Start the PowerShell process with the conversion script
            Update-Progress -Progress 0 -Details "Starting PDF to Markdown conversion"
            $process = Start-Process -FilePath "pwsh" -ArgumentList $cmdArgs -NoNewWindow -PassThru
            
            # Wait for completion
            $process.WaitForExit()
            
            # Cleanup watcher
            $fsWatcher.EnableRaisingEvents = $false
            $fsWatcher.Dispose()
            
            # Check exit code
            if ($process.ExitCode -ne 0) {
                Update-Progress -Progress 100 -Details "PDF conversion completed with errors"
                throw "Process exited with code: $($process.ExitCode)"
            }
            
            # Final progress update
            Update-Progress -Progress 100 -Details "PDF conversion completed successfully"
        }
        catch {
            Update-Progress -Progress -1 -Details "Error: $_"
            throw $_
        }
    }
    
    # Start the background job
    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath "ConvertPDFsToMarkdown.ps1"
    
    $job = Start-Job -ScriptBlock $scriptBlock -ArgumentList @(
        $scriptPath,
        $SourceDirectory,
        $OutputDirectory,
        $WatchMode,
        $PollingInterval,
        $RemoveOriginals,
        $OcrTool,
        $jobId,
        $Global:SyncLogFile
    )
    
    # Store the job for tracking
    $Global:SyncJobs[$jobId] = $job
    
    Write-ApiLog -Message "Started PDF to Markdown conversion job: $jobId" -Level "INFO"
    
    return @{
        jobId = $jobId
        state = "running"
        details = "PDF to Markdown conversion started"
    }
}

# Function to start Chroma embedding synchronization
function Start-ChromaEmbeddingSync {
    param (
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
    
    # Create a unique job ID
    $jobId = New-JobId
    
    # Initialize progress state
    $Global:ProgressStates[$jobId] = @{
        startTime = Get-Date
        progress = 0
        processed = 0
        totalFiles = 0
        details = "Initializing Chroma embedding generation"
    }
    
    # Create script block for background job
    $scriptBlock = {
        param(
            $ScriptPath,
            $FolderPath,
            $Extensions,
            $OutputFolder,
            $OllamaUrl,
            $EmbeddingModel,
            $ChunkSize,
            $WatchMode,
            $JobId
        )
        
        # Function to update progress
        function Update-Progress {
            param (
                [int]$Progress,
                [int]$Processed,
                [int]$TotalFiles,
                [string]$Details
            )
            
            # Create a temporary file with the progress info
            $progressFile = Join-Path -Path $env:TEMP -ChildPath "chroma_progress_$JobId.json"
            $progressObj = @{
                jobId = $JobId
                progress = $Progress
                processed = $Processed
                totalFiles = $TotalFiles
                details = $Details
                timestamp = (Get-Date).ToString("o")
            }
            
            $progressObj | ConvertTo-Json | Out-File -FilePath $progressFile -Force
        }
        
        try {
            # Build command arguments based on provided parameters
            $cmdArgs = @(
                "-File", $ScriptPath,
                "-FolderPath", $FolderPath,
                "-Extensions", $Extensions,
                "-OutputFolder", $OutputFolder,
                "-OllamaUrl", $OllamaUrl,
                "-EmbeddingModel", $EmbeddingModel,
                "-ChunkSize", $ChunkSize
            )
            
            if ($WatchMode) {
                $cmdArgs += "-WatchMode"
            }
            
            # Setting up output parsing to monitor progress
            $processOutput = New-Object System.Collections.ArrayList
            
            # Start the PowerShell process with the embedding script
            Update-Progress -Progress 0 -Processed 0 -TotalFiles 0 -Details "Starting Chroma embedding generation"
            
            # Create a temp script to capture and relay output
            $tempScript = @"
try {
    # Call the actual script and capture output
    & pwsh $($cmdArgs -join ' ') | ForEach-Object {
        # Echo to stdout for our process to capture
        Write-Output `$_
        
        # Parse for progress information
        if (`$_ -match "Found (\d+) files to process") {
            `$totalFiles = [int]`$matches[1]
            `$progressFile = Join-Path -Path `$env:TEMP -ChildPath "chroma_progress_$JobId.json"
            `$progressObj = @{
                jobId = "$JobId"
                progress = 0
                processed = 0
                totalFiles = `$totalFiles
                details = "Found `$totalFiles files to process"
                timestamp = (Get-Date).ToString("o")
            }
            
            `$progressObj | ConvertTo-Json | Out-File -FilePath `$progressFile -Force
        }
        elseif (`$_ -match "Processing: (\d+)/(\d+) - ([\d.]+)% - (.*)") {
            `$current = [int]`$matches[1]
            `$total = [int]`$matches[2]
            `$percentage = [double]`$matches[3]
            `$file = `$matches[4]
            
            `$progressFile = Join-Path -Path `$env:TEMP -ChildPath "chroma_progress_$JobId.json"
            `$progressObj = @{
                jobId = "$JobId"
                progress = [int]`$percentage
                processed = `$current
                totalFiles = `$total
                details = "Processing file: `$file"
                timestamp = (Get-Date).ToString("o")
            }
            
            `$progressObj | ConvertTo-Json | Out-File -FilePath `$progressFile -Force
        }
        elseif (`$_ -match "Completed processing (\d+) of (\d+) files") {
            `$successful = [int]`$matches[1]
            `$total = [int]`$matches[2]
            
            `$progressFile = Join-Path -Path `$env:TEMP -ChildPath "chroma_progress_$JobId.json"
            `$progressObj = @{
                jobId = "$JobId"
                progress = 100
                processed = `$successful
                totalFiles = `$total
                details = "Completed processing `$successful of `$total files"
                timestamp = (Get-Date).ToString("o")
            }
            
            `$progressObj | ConvertTo-Json | Out-File -FilePath `$progressFile -Force
        }
    }
    exit 0
}
catch {
    Write-Error "Error in wrapper script: `$_"
    exit 1
}
"@
            
            $tempScriptPath = Join-Path -Path $env:TEMP -ChildPath "chromascript_$JobId.ps1"
            $tempScript | Out-File -FilePath $tempScriptPath -Encoding utf8
            
            $process = Start-Process -FilePath "pwsh" -ArgumentList "-File", $tempScriptPath -NoNewWindow -PassThru
            
            # Wait for completion
            $process.WaitForExit()
            
            # Cleanup
            if (Test-Path $tempScriptPath) {
                Remove-Item $tempScriptPath -Force
            }
            
            # Check exit code
            if ($process.ExitCode -ne 0) {
                Update-Progress -Progress 100 -Processed 0 -TotalFiles 0 -Details "Embedding generation completed with errors"
                throw "Process exited with code: $($process.ExitCode)"
            }
            
            # Final progress update
            Update-Progress -Progress 100 -Processed 0 -TotalFiles 0 -Details "Embedding generation completed successfully"
        }
        catch {
            Update-Progress -Progress -1 -Processed 0 -TotalFiles 0 -Details "Error: $_"
            throw $_
        }
    }
    
    # Start the background job
    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath "CreateChromaEmbeddings.ps1"
    
    $job = Start-Job -ScriptBlock $scriptBlock -ArgumentList @(
        $scriptPath,
        $FolderPath,
        $Extensions,
        $OutputFolder,
        $OllamaUrl,
        $EmbeddingModel,
        $ChunkSize,
        $WatchMode,
        $jobId
    )
    
    # Store the job for tracking
    $Global:SyncJobs[$jobId] = $job
    
    Write-ApiLog -Message "Started Chroma embedding job: $jobId" -Level "INFO"
    
    return @{
        jobId = $jobId
        state = "running"
        details = "Chroma embedding generation started"
    }
}

# Function to stop a running synchronization job
function Stop-SyncJob {
    param (
        [Parameter(Mandatory=$true)]
        [string]$JobId
    )
    
    # Check if job exists
    if (-not $Global:SyncJobs.ContainsKey($JobId)) {
        Write-ApiLog -Message "Job not found: $JobId" -Level "ERROR"
        return @{
            jobId = $JobId
            state = "error"
            details = "Job not found"
        }
    }
    
    $job = $Global:SyncJobs[$JobId]
    
    # Check if job is still running
    if ($job.State -eq "Running") {
        # Stop the job
        $job | Stop-Job -PassThru | Remove-Job -Force
        
        # Update progress state
        if ($Global:ProgressStates.ContainsKey($JobId)) {
            $Global:ProgressStates[$JobId].details = "Job stopped by user"
        }
        
        Write-ApiLog -Message "Stopped job: $JobId" -Level "INFO"
        
        return @{
            jobId = $JobId
            state = "stopped"
            details = "Job stopped successfully"
        }
    }
    else {
        # Job is already completed/failed/stopped
        Write-ApiLog -Message "Job is not running: $JobId (State: $($job.State))" -Level "WARNING"
        
        return @{
            jobId = $JobId
            state = $job.State.ToLower()
            details = "Job is not running (State: $($job.State))"
        }
    }
}

# Function to list all jobs and their status
function Get-AllJobs {
    $jobList = @()
    
    foreach ($jobId in $Global:SyncJobs.Keys) {
        # Get job type from the progress state
        $jobType = ""
        if ($Global:ProgressStates.ContainsKey($jobId) -and $Global:ProgressStates[$jobId].ContainsKey("totalFiles")) {
            $jobType = "chromaEmbedding"
            $status = Get-ChromaEmbeddingStatus -JobId $jobId
        }
        else {
            $jobType = "pdfToMarkdown"
            $status = Get-PdfToMarkdownStatus -JobId $jobId
        }
        
        $jobList += @{
            jobId = $jobId
            type = $jobType
            status = $status
        }
    }
    
    return @{
        count = $jobList.Count
        jobs = $jobList
    }
}

# Run a background job to clean up completed/failed jobs after a certain time
$cleanupJob = Start-Job -ScriptBlock {
    while ($true) {
        # Every 10 minutes, check for jobs that are completed/failed and are older than 24 hours
        Start-Sleep -Seconds 600
        
        $currentTime = Get-Date
        $jobsToRemove = @()
        
        foreach ($jobId in $Global:SyncJobs.Keys) {
            $job = $Global:SyncJobs[$jobId]
            
            # Skip jobs that are still running
            if ($job.State -eq "Running") {
                continue
            }
            
            # Check if job has a progress state and if it's older than 24 hours
            if ($Global:ProgressStates.ContainsKey($jobId)) {
                $startTime = $Global:ProgressStates[$jobId].startTime
                $timeDiff = $currentTime - $startTime
                
                if ($timeDiff.TotalHours -ge 24) {
                    $jobsToRemove += $jobId
                }
            }
        }
        
        # Remove old jobs
        foreach ($jobId in $jobsToRemove) {
            try {
                $Global:SyncJobs[$jobId] | Remove-Job -Force -ErrorAction SilentlyContinue
                $Global:SyncJobs.Remove($jobId)
                $Global:ProgressStates.Remove($jobId)
                
                Write-ApiLog -Message "Cleaned up old job: $jobId" -Level "INFO"
            }
            catch {
                Write-ApiLog -Message "Error cleaning up job $jobId : $_" -Level "ERROR"
            }
        }
    }
}

# Refresh progress from temp files
function Start-ProgressMonitor {
    $monitorJob = Start-Job -ScriptBlock {
        while ($true) {
            # Every second, check for progress files
            Start-Sleep -Seconds 1
            
            foreach ($jobId in $Global:SyncJobs.Keys) {
                $job = $Global:SyncJobs[$jobId]
                
                # Skip jobs that are not running
                if ($job.State -ne "Running") {
                    continue
                }
                
                # Check if job has a progress file
                $pdfProgressFile = Join-Path -Path $env:TEMP -ChildPath "pdf2md_progress_$jobId.json"
                $chromaProgressFile = Join-Path -Path $env:TEMP -ChildPath "chroma_progress_$jobId.json"
                
                if (Test-Path $pdfProgressFile) {
                    try {
                        $progressData = Get-Content -Path $pdfProgressFile -Raw | ConvertFrom-Json
                        
                        # Update progress state
                        $Global:ProgressStates[$jobId].progress = $progressData.progress
                        $Global:ProgressStates[$jobId].details = $progressData.details
                    }
                    catch {
                        # Ignore errors reading progress file
                    }
                }
                elseif (Test-Path $chromaProgressFile) {
                    try {
                        $progressData = Get-Content -Path $chromaProgressFile -Raw | ConvertFrom-Json
                        
                        # Update progress state
                        $Global:ProgressStates[$jobId].progress = $progressData.progress
                        $Global:ProgressStates[$jobId].processed = $progressData.processed
                        $Global:ProgressStates[$jobId].totalFiles = $progressData.totalFiles
                        $Global:ProgressStates[$jobId].details = $progressData.details
                    }
                    catch {
                        # Ignore errors reading progress file
                    }
                }
            }
        }
    }
    
    return $monitorJob
}

# Start progress monitor
$progressMonitor = Start-ProgressMonitor

# Set up HTTP listener
$listener = New-Object System.Net.HttpListener
if ($UseHttps) {
    $prefix = "https://$($ListenAddress):$Port/"
    
    # Note: HTTPS requires a valid certificate to be bound to the port
    Write-ApiLog -Message "HTTPS requires a certificate to be bound to port $Port" -Level "WARNING"
    Write-ApiLog -Message "You may need to run: netsh http add sslcert ipport=0.0.0.0:$Port certhash=THUMBPRINT appid={GUID}" -Level "INFO"
}
else {
    $prefix = "http://$($ListenAddress):$Port/"
}

$listener.Prefixes.Add($prefix)

try {
    # Start the listener
    $listener.Start()
    
    Write-ApiLog -Message "API server started at $prefix" -Level "INFO"
    Write-ApiLog -Message "Press Ctrl+C to stop the server" -Level "INFO"
    
    # Handle requests in a loop
    while ($listener.IsListening) {
        $context = $null
        try {
            # Get request context
            $context = $listener.GetContext()
            
            # Get request and response objects
            $request = $context.Request
            $response = $context.Response
            
            # Parse URL to extract route
            $route = $request.Url.LocalPath
            $method = $request.HttpMethod
            
            Write-ApiLog -Message "Received $method request for $route" -Level "INFO"
            
            # Set default content type to JSON
            $response.ContentType = "application/json"
            
            # Parse request body if needed
            $requestBody = $null
            if ($request.HasEntityBody) {
                $reader = New-Object System.IO.StreamReader $request.InputStream
                $requestBody = $reader.ReadToEnd()
                $reader.Close()
                
                # Try to parse JSON body
                try {
                    $requestBody = $requestBody | ConvertFrom-Json
                }
                catch {
                    # Leave as string if not valid JSON
                }
            }
            
            # Handle based on route and method
            $responseBody = $null
            $statusCode = 200
            
            switch ($route) {
                # --- Health check and API info ---
                "/" {
                    if ($method -eq "GET") {
                        $responseBody = @{
                            status = "ok"
                            message = "API server running"
                            routes = @(
                                "/jobs - GET: List all jobs",
                                "/jobs/pdf - POST: Start PDF to Markdown conversion",
                                "/jobs/chroma - POST: Start Chroma embedding generation",
                                "/jobs/{id} - GET: Get job status",
                                "/jobs/{id}/stop - POST: Stop a running job"
                            )
                        }
                    }
                    else {
                        $statusCode = 405
                        $responseBody = @{
                            error = "Method not allowed"
                            message = "Use GET for this endpoint"
                        }
                    }
                }
                
                # --- List all jobs ---
                "/jobs" {
                    if ($method -eq "GET") {
                        $responseBody = Get-AllJobs
                    }
                    else {
                        $statusCode = 405
                        $responseBody = @{
                            error = "Method not allowed"
                            message = "Use GET for this endpoint"
                        }
                    }
                }
                
                # --- Start PDF to Markdown conversion ---
                "/jobs/pdf" {
                    if ($method -eq "POST") {
                        # Validate required parameters
                        if ($null -eq $requestBody -or 
                            $null -eq $requestBody.sourceDirectory -or 
                            $null -eq $requestBody.outputDirectory) {
                            
                            $statusCode = 400
                            $responseBody = @{
                                error = "Bad request"
                                message = "Required parameters missing: sourceDirectory, outputDirectory"
                            }
                        }
                        else {
                            # Extract parameters
                            $sourceDir = $requestBody.sourceDirectory
                            $outputDir = $requestBody.outputDirectory
                            $watchMode = $requestBody.watchMode -eq $true
                            $pollingInterval = if ($null -ne $requestBody.pollingInterval) { $requestBody.pollingInterval } else { 30 }
                            $removeOriginals = $requestBody.removeOriginals -eq $true
                            $ocrTool = if ($null -ne $requestBody.ocrTool) { $requestBody.ocrTool } else { "marker" }
                            
                            # Start conversion
                            $responseBody = Start-PdfToMarkdownSync `
                                -SourceDirectory $sourceDir `
                                -OutputDirectory $outputDir `
                                -WatchMode:$watchMode `
                                -PollingInterval $pollingInterval `
                                -RemoveOriginals:$removeOriginals `
                                -OcrTool $ocrTool
                        }
                    }
                }
                
                # --- Start Chroma embedding generation ---
                "/jobs/chroma" {
                    if ($method -eq "POST") {
                        # Validate required parameters
                        if ($null -eq $requestBody -or 
                            $null -eq $requestBody.folderPath) {
                            
                            $statusCode = 400
                            $responseBody = @{
                                error = "Bad request"
                                message = "Required parameter missing: folderPath"
                            }
                        }
                        else {
                            # Extract parameters
                            $folderPath = $requestBody.folderPath
                            $extensions = if ($null -ne $requestBody.extensions) { $requestBody.extensions } else { ".txt,.md,.html,.csv,.json" }
                            $outputFolder = if ($null -ne $requestBody.outputFolder) { $requestBody.outputFolder } else { "./chroma_db" }
                            $ollamaUrl = if ($null -ne $requestBody.ollamaUrl) { $requestBody.ollamaUrl } else { "http://localhost:11434" }
                            $embeddingModel = if ($null -ne $requestBody.embeddingModel) { $requestBody.embeddingModel } else { "mxbai-embed-large:latest" }
                            $chunkSize = if ($null -ne $requestBody.chunkSize) { $requestBody.chunkSize } else { 100000 }
                            $watchMode = $requestBody.watchMode -eq $true
                            
                            # Start embedding generation
                            $responseBody = Start-ChromaEmbeddingSync `
                                -FolderPath $folderPath `
                                -Extensions $extensions `
                                -OutputFolder $outputFolder `
                                -OllamaUrl $ollamaUrl `
                                -EmbeddingModel $embeddingModel `
                                -ChunkSize $chunkSize `
                                -WatchMode:$watchMode
                        }
                    }
                    else {
                        $statusCode = 405
                        $responseBody = @{
                            error = "Method not allowed"
                            message = "Use POST for this endpoint"
                        }
                    }
                }
                
                # --- Get job status ---
                {$_ -match "^/jobs/([^/]+)$"} {
                    $jobId = $matches[1]
                    
                    if ($method -eq "GET") {
                        # Check if job exists
                        if (-not $Global:SyncJobs.ContainsKey($jobId)) {
                            $statusCode = 404
                            $responseBody = @{
                                error = "Job not found"
                                message = "No job with ID $jobId exists"
                            }
                        }
                        else {
                            # Determine job type based on progress state structure
                            if ($Global:ProgressStates.ContainsKey($jobId) -and $Global:ProgressStates[$jobId].ContainsKey("totalFiles")) {
                                # Chroma embedding job
                                $responseBody = Get-ChromaEmbeddingStatus -JobId $jobId
                            }
                            else {
                                # PDF to Markdown job
                                $responseBody = Get-PdfToMarkdownStatus -JobId $jobId
                            }
                        }
                    }
                    else {
                        $statusCode = 405
                        $responseBody = @{
                            error = "Method not allowed"
                            message = "Use GET for this endpoint"
                        }
                    }
                }
                
                # --- Stop a job ---
                {$_ -match "^/jobs/([^/]+)/stop$"} {
                    $jobId = $matches[1]
                    
                    if ($method -eq "POST") {
                        $responseBody = Stop-SyncJob -JobId $jobId
                        
                        if ($responseBody.state -eq "error") {
                            $statusCode = 404
                        }
                    }
                    else {
                        $statusCode = 405
                        $responseBody = @{
                            error = "Method not allowed"
                            message = "Use POST for this endpoint"
                        }
                    }
                }
                
                # --- Handle unknown routes ---
                default {
                    $statusCode = 404
                    $responseBody = @{
                        error = "Route not found"
                        message = "The requested resource does not exist: $route"
                    }
                }
            }
            
            # Convert response to JSON
            $jsonResponse = $responseBody | ConvertTo-Json -Depth 10
            
            # Set status code
            $response.StatusCode = $statusCode
            
            # Write response
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($jsonResponse)
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
            $response.OutputStream.Close()
            
        }
        catch {
            Write-ApiLog -Message "Error handling request: $_" -Level "ERROR"
            
            # Try to send error response if context is available
            if ($null -ne $context -and $null -ne $response) {
                try {
                    $response.StatusCode = 500
                    $response.ContentType = "application/json"
                    
                    $errorJson = @{
                        error = "Internal server error"
                        message = $_.ToString()
                    } | ConvertTo-Json
                    
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($errorJson)
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                    $response.OutputStream.Close()
                }
                catch {
                    # Ignore errors in error handling
                }
            }
        }
    }
}
catch {
    Write-ApiLog -Message "Fatal error in API server: $_" -Level "ERROR"
}
finally {
    # Clean up
    if ($null -ne $listener -and $listener.IsListening) {
        $listener.Stop()
        $listener.Close()
    }
    
    # Stop background jobs
    if ($null -ne $cleanupJob) {
        $cleanupJob | Stop-Job -PassThru | Remove-Job -Force
    }
    
    if ($null -ne $progressMonitor) {
        $progressMonitor | Stop-Job -PassThru | Remove-Job -Force
    }
    
    # Stop any running sync jobs
    foreach ($jobId in $Global:SyncJobs.Keys) {
        $job = $Global:SyncJobs[$jobId]
        if ($job.State -eq "Running") {
            $job | Stop-Job -PassThru | Remove-Job -Force
        }
    }
    
    Write-ApiLog -Message "API server stopped" -Level "INFO"
}
