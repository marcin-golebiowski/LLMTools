# SyncClient.ps1
# Client script to interact with the Synchronization REST API
# Provides commands to start, monitor, and stop synchronization operations

#Requires -Version 7.0

param (
    [Parameter(Mandatory=$false)]
    [string]$ApiUrl = "http://localhost:8080",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("check", "list", "start-pdf", "start-chroma", "status", "stop", "monitor")]
    [string]$Command = "check",
    
    [Parameter(Mandatory=$false)]
    [string]$JobId,
    
    [Parameter(Mandatory=$false)]
    [string]$SourceDirectory,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory,
    
    [Parameter(Mandatory=$false)]
    [string]$FolderPath,
    
    [Parameter(Mandatory=$false)]
    [string]$Extensions,
    
    [Parameter(Mandatory=$false)]
    [string]$OcrTool = "marker",
    
    [Parameter(Mandatory=$false)]
    [string]$EmbeddingModel = "mxbai-embed-large:latest",
    
    [Parameter(Mandatory=$false)]
    [switch]$WatchMode,
    
    [Parameter(Mandatory=$false)]
    [switch]$RemoveOriginals,
    
    [Parameter(Mandatory=$false)]
    [int]$RefreshInterval = 5,
    
    [Parameter(Mandatory=$false)]
    [int]$PollingInterval = 30,
    
    [Parameter(Mandatory=$false)]
    [int]$ChunkSize = 100000
)

# Function to make API requests
function Invoke-ApiRequest {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Endpoint,
        
        [Parameter(Mandatory=$false)]
        [string]$Method = "GET",
        
        [Parameter(Mandatory=$false)]
        [object]$Body = $null
    )
    
    $uri = "$ApiUrl$Endpoint"
    $params = @{
        Method = $Method
        Uri = $uri
        ErrorAction = "Stop"
    }
    
    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json)
        $params.ContentType = "application/json"
    }
    
    try {
        $response = Invoke-RestMethod @params
        return $response
    }
    catch {
        Write-Host "ERROR: API request failed - $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode.value__
            Write-Host "Status code: $statusCode" -ForegroundColor Red
            
            if ($_.ErrorDetails.Message) {
                try {
                    $errorObj = $_.ErrorDetails.Message | ConvertFrom-Json
                    Write-Host "Error details: $($errorObj.error) - $($errorObj.message)" -ForegroundColor Red
                }
                catch {
                    Write-Host "Error details: $($_.ErrorDetails.Message)" -ForegroundColor Red
                }
            }
        }
        return $null
    }
}

# Function to format and display job status
function Format-JobStatus {
    param (
        [Parameter(Mandatory=$true)]
        [object]$Status
    )
    
    $progressBar = ""
    if ($Status.progress -gt 0 -and $Status.progress -le 100) {
        $completed = [math]::Floor($Status.progress / 5)
        $remaining = 20 - $completed
        $progressBar = "[" + ("█" * $completed) + ("░" * $remaining) + "]"
    }
    
    $output = "`n"
    $output += "Job ID:     $($Status.jobId)`n"
    $output += "State:      $($Status.state)`n"
    $output += "Details:    $($Status.details)`n"
    
    if ($Status.progress -ge 0) {
        $output += "Progress:   $($Status.progress)% $progressBar`n"
    }
    
    if ($Status.PSObject.Properties.Name -contains "processed" -and 
        $Status.PSObject.Properties.Name -contains "totalFiles") {
        $output += "Files:      $($Status.processed)/$($Status.totalFiles)`n"
    }
    
    if ($Status.PSObject.Properties.Name -contains "startTime") {
        $startTime = [datetime]$Status.startTime
        $output += "Start Time: $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))`n"
    }
    
    if ($Status.PSObject.Properties.Name -contains "runtime") {
        $runtime = [TimeSpan]::FromSeconds($Status.runtime)
        $output += "Runtime:    $($runtime.ToString('hh\:mm\:ss'))`n"
    }
    
    return $output
}

# Function to display a progress spinner
function Show-Spinner {
    param (
        [Parameter(Mandatory=$true)]
        [int]$Duration,
        
        [Parameter(Mandatory=$true)]
        [string]$Message
    )
    
    $spinChars = '|', '/', '-', '\'
    $startTime = Get-Date
    $endTime = $startTime.AddSeconds($Duration)
    
    $spinIndex = 0
    
    while ((Get-Date) -lt $endTime) {
        Write-Host "`r$($spinChars[$spinIndex]) $Message" -NoNewline
        Start-Sleep -Milliseconds 200
        $spinIndex = ($spinIndex + 1) % $spinChars.Length
    }
    
    Write-Host "`r  $Message" -NoNewline
}

# Check API connection
function Test-ApiConnection {
    $response = Invoke-ApiRequest -Endpoint "/"
    
    if ($response) {
        Write-Host "Connected to Synchronization API at $ApiUrl" -ForegroundColor Green
        Write-Host "API Status: $($response.status)" -ForegroundColor Green
        Write-Host "Available Routes:" -ForegroundColor Cyan
        foreach ($route in $response.routes) {
            Write-Host "  $route" -ForegroundColor Gray
        }
        return $true
    }
    else {
        Write-Host "Failed to connect to API at $ApiUrl" -ForegroundColor Red
        Write-Host "Make sure the API server is running by executing: .\ApiServer.ps1" -ForegroundColor Yellow
        return $false
    }
}

# List all jobs
function Get-AllJobs {
    $response = Invoke-ApiRequest -Endpoint "/jobs"
    
    if ($response) {
        if ($response.count -eq 0) {
            Write-Host "No active jobs found." -ForegroundColor Yellow
            return
        }
        
        Write-Host "Found $($response.count) job(s):" -ForegroundColor Cyan
        
        foreach ($job in $response.jobs) {
            Write-Host "`nJob ID: $($job.jobId) (Type: $($job.type))" -ForegroundColor Green
            Write-Host "Status: $($job.status.state) - $($job.status.details)" -ForegroundColor Cyan
            
            if ($job.status.progress -ge 0) {
                $completed = [math]::Floor($job.status.progress / 5)
                $remaining = 20 - $completed
                $progressBar = "[" + ("█" * $completed) + ("░" * $remaining) + "]"
                Write-Host "Progress: $($job.status.progress)% $progressBar" -ForegroundColor Gray
            }
        }
    }
}

# Get status of a specific job
function Get-JobStatus {
    param (
        [Parameter(Mandatory=$true)]
        [string]$JobId
    )
    
    $response = Invoke-ApiRequest -Endpoint "/jobs/$JobId"
    
    if ($response) {
        $statusString = Format-JobStatus -Status $response
        Write-Host $statusString -ForegroundColor Cyan
    }
}

# Start PDF to Markdown conversion job
function Start-PdfToMarkdownJob {
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
        [string]$OcrTool = "marker"
    )
    
    # Validate input
    if (-not (Test-Path -Path $SourceDirectory)) {
        Write-Host "ERROR: Source directory does not exist: $SourceDirectory" -ForegroundColor Red
        return
    }
    
    if (-not (Test-Path -Path $OutputDirectory)) {
        $createDir = Read-Host "Output directory does not exist: $OutputDirectory. Create it? (y/n)"
        if ($createDir -eq "y") {
            New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
        }
        else {
            Write-Host "Operation cancelled." -ForegroundColor Yellow
            return
        }
    }
    
    # Build request body
    $body = @{
        sourceDirectory = $SourceDirectory
        outputDirectory = $OutputDirectory
        watchMode = $WatchMode.IsPresent
        pollingInterval = $PollingInterval
        removeOriginals = $RemoveOriginals.IsPresent
        ocrTool = $OcrTool
    }
    
    Write-Host "Starting PDF to Markdown conversion job..." -ForegroundColor Cyan
    Show-Spinner -Duration 2 -Message "Sending request to API..."
    
    $response = Invoke-ApiRequest -Endpoint "/jobs/pdf" -Method "POST" -Body $body
    
    if ($response) {
        Write-Host "`nJob started successfully!" -ForegroundColor Green
        Write-Host "Job ID: $($response.jobId)" -ForegroundColor Green
        Write-Host "Initial State: $($response.state)" -ForegroundColor Cyan
        Write-Host "Details: $($response.details)" -ForegroundColor Gray
        Write-Host "`nYou can check the status with: .\SyncClient.ps1 -Command status -JobId $($response.jobId)" -ForegroundColor Yellow
        
        return $response.jobId
    }
}

# Start Chroma embedding generation job
function Start-ChromaEmbeddingJob {
    param (
        [Parameter(Mandatory=$true)]
        [string]$FolderPath,
        
        [Parameter(Mandatory=$false)]
        [string]$Extensions,
        
        [Parameter(Mandatory=$false)]
        [string]$OutputFolder,
        
        [Parameter(Mandatory=$false)]
        [string]$EmbeddingModel,
        
        [Parameter(Mandatory=$false)]
        [int]$ChunkSize,
        
        [Parameter(Mandatory=$false)]
        [switch]$WatchMode
    )
    
    # Validate input
    if (-not (Test-Path -Path $FolderPath)) {
        Write-Host "ERROR: Folder path does not exist: $FolderPath" -ForegroundColor Red
        return
    }
    
    # Build request body
    $body = @{
        folderPath = $FolderPath
        watchMode = $WatchMode.IsPresent
    }
    
    if ($Extensions) {
        $body.extensions = $Extensions
    }
    
    if ($OutputFolder) {
        $body.outputFolder = $OutputFolder
    }
    
    if ($EmbeddingModel) {
        $body.embeddingModel = $EmbeddingModel
    }
    
    if ($ChunkSize -gt 0) {
        $body.chunkSize = $ChunkSize
    }
    
    Write-Host "Starting Chroma embedding generation job..." -ForegroundColor Cyan
    Show-Spinner -Duration 2 -Message "Sending request to API..."
    
    $response = Invoke-ApiRequest -Endpoint "/jobs/chroma" -Method "POST" -Body $body
    
    if ($response) {
        Write-Host "`nJob started successfully!" -ForegroundColor Green
        Write-Host "Job ID: $($response.jobId)" -ForegroundColor Green
        Write-Host "Initial State: $($response.state)" -ForegroundColor Cyan
        Write-Host "Details: $($response.details)" -ForegroundColor Gray
        Write-Host "`nYou can check the status with: .\SyncClient.ps1 -Command status -JobId $($response.jobId)" -ForegroundColor Yellow
        
        return $response.jobId
    }
}

# Stop a running job
function Stop-SyncJob {
    param (
        [Parameter(Mandatory=$true)]
        [string]$JobId
    )
    
    Write-Host "Stopping job $JobId..." -ForegroundColor Yellow
    Show-Spinner -Duration 2 -Message "Sending stop request..."
    
    $response = Invoke-ApiRequest -Endpoint "/jobs/$JobId/stop" -Method "POST"
    
    if ($response) {
        Write-Host "`nStop request sent." -ForegroundColor Green
        Write-Host "Job State: $($response.state)" -ForegroundColor Cyan
        Write-Host "Details: $($response.details)" -ForegroundColor Gray
    }
}

# Monitor a job with live updates
function Start-JobMonitor {
    param (
        [Parameter(Mandatory=$true)]
        [string]$JobId,
        
        [Parameter(Mandatory=$false)]
        [int]$RefreshInterval = 5
    )
    
    Write-Host "Starting job monitor for job $JobId" -ForegroundColor Cyan
    Write-Host "Press Ctrl+C to stop monitoring" -ForegroundColor Yellow
    
    try {
        $lastStatus = $null
        
        while ($true) {
            $response = Invoke-ApiRequest -Endpoint "/jobs/$JobId"
            
            if (-not $response) {
                Write-Host "Job not found or unable to retrieve status." -ForegroundColor Red
                return
            }
            
            $currentStatus = $response.state
            
            # Clear screen and show full status
            Clear-Host
            
            Write-Host "== MONITORING JOB: $JobId ==" -ForegroundColor Cyan
            Write-Host "Last update: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
            Write-Host "Refresh interval: ${RefreshInterval}s (Press Ctrl+C to exit)" -ForegroundColor Gray
            
            $statusString = Format-JobStatus -Status $response
            Write-Host $statusString -ForegroundColor Cyan
            
            # Check for completed state
            if ($currentStatus -eq "completed" -or $currentStatus -eq "failed" -or $currentStatus -eq "stopped") {
                Write-Host "Job has completed with status: $currentStatus" -ForegroundColor Yellow
                
                if ($currentStatus -eq "completed") {
                    Write-Host "Job completed successfully!" -ForegroundColor Green
                }
                elseif ($currentStatus -eq "failed") {
                    Write-Host "Job failed. Check the details above for more information." -ForegroundColor Red
                }
                else {
                    Write-Host "Job was stopped." -ForegroundColor Yellow
                }
                
                break
            }
            
            # Sleep for the refresh interval
            Start-Sleep -Seconds $RefreshInterval
        }
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        # User pressed Ctrl+C
        Write-Host "`nMonitoring stopped by user." -ForegroundColor Yellow
    }
}

# Display help information
function Show-Help {
    $helpText = @"

SYNC CLIENT - A utility to interact with the Synchronization REST API

USAGE:
  .\SyncClient.ps1 -Command <command> [options]

COMMANDS:
  check                Check API connection
  list                 List all jobs
  status -JobId <id>   Get status of a specific job
  monitor -JobId <id>  Monitor a job with live updates
  stop -JobId <id>     Stop a running job
  start-pdf            Start a PDF to Markdown conversion job
  start-chroma         Start a Chroma embedding generation job

OPTIONS:
  -ApiUrl <url>        API server URL (default: http://localhost:8080)
  -RefreshInterval <n> Seconds between updates in monitor mode (default: 5)

PDF TO MARKDOWN OPTIONS:
  -SourceDirectory <path>  Directory containing PDF files to convert
  -OutputDirectory <path>  Directory to save converted Markdown files
  -OcrTool <tool>          OCR tool to use: marker, tesseract, ocrmypdf, pymupdf
  -WatchMode               Enable monitoring for new files
  -PollingInterval <n>     Interval in seconds to check for new files
  -RemoveOriginals         Remove original PDF files after conversion

CHROMA EMBEDDING OPTIONS:
  -FolderPath <path>       Directory containing text files to process
  -Extensions <list>       Comma-separated list of file extensions
  -OutputDirectory <path>  Directory to save Chroma database
  -EmbeddingModel <model>  Embedding model to use
  -ChunkSize <n>           Maximum size of text chunks in characters
  -WatchMode               Enable monitoring for file changes

EXAMPLES:
  # Check API connection
  .\SyncClient.ps1 -Command check

  # List all jobs
  .\SyncClient.ps1 -Command list

  # Start PDF to Markdown conversion
  .\SyncClient.ps1 -Command start-pdf -SourceDirectory "C:\PDFSource" -OutputDirectory "C:\PDFOutput"

  # Start Chroma embedding generation
  .\SyncClient.ps1 -Command start-chroma -FolderPath "C:\PDFOutput"

  # Check job status
  .\SyncClient.ps1 -Command status -JobId "job-1-12345"

  # Monitor a job with live updates
  .\SyncClient.ps1 -Command monitor -JobId "job-1-12345" -RefreshInterval 3

  # Stop a job
  .\SyncClient.ps1 -Command stop -JobId "job-1-12345"

"@

    Write-Host $helpText
}

# Main script execution
try {
    switch ($Command) {
        "check" {
            Test-ApiConnection
        }
        "list" {
            if (Test-ApiConnection) {
                Get-AllJobs
            }
        }
        "status" {
            if ($JobId) {
                if (Test-ApiConnection) {
                    Get-JobStatus -JobId $JobId
                }
            }
            else {
                Write-Host "ERROR: JobId parameter is required for status command" -ForegroundColor Red
                Show-Help
            }
        }
        "stop" {
            if ($JobId) {
                if (Test-ApiConnection) {
                    Stop-SyncJob -JobId $JobId
                }
            }
            else {
                Write-Host "ERROR: JobId parameter is required for stop command" -ForegroundColor Red
                Show-Help
            }
        }
        "monitor" {
            if ($JobId) {
                if (Test-ApiConnection) {
                    Start-JobMonitor -JobId $JobId -RefreshInterval $RefreshInterval
                }
            }
            else {
                Write-Host "ERROR: JobId parameter is required for monitor command" -ForegroundColor Red
                Show-Help
            }
        }
        "start-pdf" {
            if ($SourceDirectory -and $OutputDirectory) {
                if (Test-ApiConnection) {
                    $jobId = Start-PdfToMarkdownJob `
                        -SourceDirectory $SourceDirectory `
                        -OutputDirectory $OutputDirectory `
                        -WatchMode:$WatchMode `
                        -PollingInterval $PollingInterval `
                        -RemoveOriginals:$RemoveOriginals `
                        -OcrTool $OcrTool
                    
                    if ($jobId) {
                        $monitorNow = Read-Host "Would you like to monitor this job now? (y/n)"
                        if ($monitorNow -eq "y") {
                            Start-JobMonitor -JobId $jobId -RefreshInterval $RefreshInterval
                        }
                    }
                }
            }
            else {
                Write-Host "ERROR: SourceDirectory and OutputDirectory parameters are required for start-pdf command" -ForegroundColor Red
                Show-Help
            }
        }
        "start-chroma" {
            if ($FolderPath) {
                if (Test-ApiConnection) {
                    $jobId = Start-ChromaEmbeddingJob `
                        -FolderPath $FolderPath `
                        -Extensions $Extensions `
                        -OutputFolder $OutputDirectory `
                        -EmbeddingModel $EmbeddingModel `
                        -ChunkSize $ChunkSize `
                        -WatchMode:$WatchMode
                    
                    if ($jobId) {
                        $monitorNow = Read-Host "Would you like to monitor this job now? (y/n)"
                        if ($monitorNow -eq "y") {
                            Start-JobMonitor -JobId $jobId -RefreshInterval $RefreshInterval
                        }
                    }
                }
            }
            else {
                Write-Host "ERROR: FolderPath parameter is required for start-chroma command" -ForegroundColor Red
                Show-Help
            }
        }
        default {
            Show-Help
        }
    }
}
catch {
    Write-Host "ERROR: An unhandled exception occurred - $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
}
