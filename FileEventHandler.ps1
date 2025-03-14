# FileEventHandler.ps1
# This is a sample script to process file events passed from FileWatcherProcessor.ps1

param (
    [Parameter(Mandatory = $true)]
    [string]$EventDataPath,
    
    [Parameter(Mandatory = $false)]
    [string]$LogPath = ""
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

function Process-File {
    param (
        [string]$FilePath,
        [string]$ChangeType
    )
    
    # This is where you would implement your custom file processing logic
    # For example:
    Write-Log "Processing file: $FilePath (Change: $ChangeType)"
    
    # Example: Check if file exists (for non-delete events)
    if ($ChangeType -ne "Deleted" -and (Test-Path -Path $FilePath)) {
        # Get file information
        $fileInfo = Get-Item -Path $FilePath
        $fileSize = $fileInfo.Length
        $fileExtension = $fileInfo.Extension
        
        Write-Log "File details: Size=$fileSize bytes, Extension=$fileExtension"
        
        # Example: Different processing based on file type
        switch ($fileExtension.ToLower()) {
            ".txt" {
                Write-Log "Processing text file..."
                $content = Get-Content -Path $FilePath -Raw
                Write-Log "Text file contains $(($content -split '\r?\n').Count) lines"
            }
            ".json" {
                Write-Log "Processing JSON file..."
                try {
                    $json = Get-Content -Path $FilePath -Raw | ConvertFrom-Json
                    Write-Log "Successfully parsed JSON file"
                }
                catch {
                    Write-Log "Error parsing JSON: $_" -Level "ERROR"
                }
            }
            ".ps1" {
                Write-Log "Processing PowerShell script..."
                Write-Log "Script file: $FilePath"
                # Example: You could run a syntax check on the script
                # $syntaxErrors = $null
                # $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Path $FilePath -Raw), [ref]$syntaxErrors)
                # Write-Log "Script has $($syntaxErrors.Count) syntax errors"
            }
            default {
                Write-Log "No special processing for extension: $fileExtension"
            }
        }
        
        return "Processed file: $FilePath successfully"
    }
    elseif ($ChangeType -eq "Deleted") {
        Write-Log "File was deleted: $FilePath"
        return "Processed delete event for: $FilePath"
    }
    else {
        Write-Log "File does not exist: $FilePath" -Level "WARNING"
        return "File not found: $FilePath"
    }
}

# Main execution
try {
    # Load event data from the temp file
    if (Test-Path -Path $EventDataPath) {
        $eventData = Get-Content -Path $EventDataPath -Raw | ConvertFrom-Json
        
        Write-Log "Handling event for file: $($eventData.FilePath)"
        Write-Log "Event type: $($eventData.ChangeType)"
        
        # Process the file based on event data
        $result = Process-File -FilePath $eventData.FilePath -ChangeType $eventData.ChangeType
        
        # Clean up temp file
        Remove-Item -Path $EventDataPath -Force
        
        # Return result (will be captured by parent process if using jobs)
        return $result
    }
    else {
        Write-Log "Event data file not found: $EventDataPath" -Level "ERROR"
        return "ERROR: Event data file not found"
    }
}
catch {
    Write-Log "Error processing event: $_" -Level "ERROR"
    return "ERROR: $_"
}
