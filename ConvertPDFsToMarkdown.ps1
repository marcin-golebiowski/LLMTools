# PDF to Markdown/TXT Processor Script
# This script processes PDF files from a directory and converts them to Markdown and TXT formats
# using the marker Python library

#Requires -Version 7.0

param (
    [Parameter(Mandatory=$false)]
    [string]$SourceDirectory = "C:\PDFSource",
    
    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory = "C:\PDFOutput",
    
    [Parameter(Mandatory=$false)]
    [switch]$WatchMode,
    
    [Parameter(Mandatory=$false)]
    [int]$PollingInterval = 30, # in seconds, only used with WatchMode
    
    [Parameter(Mandatory=$false)]
    [switch]$RemoveOriginals
)

# Set up logging
$LogFile = Join-Path -Path $OutputDirectory -ChildPath "pdf-processor.log"

function Write-Log {
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
    elseif ($Verbose -or $Level -eq "INFO") {
        Write-Host $logMessage -ForegroundColor Cyan
    }
    
    # Ensure log directory exists
    $logDir = Split-Path -Path $LogFile -Parent
    if (-not (Test-Path -Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    
    # Write to log file
    Add-Content -Path $LogFile -Value $logMessage
}

# Function to install the marker library if not already installed
function Install-MarkerLibrary {
    try {
        # Check if Python is installed
        if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
            Write-Log -Level "ERROR" -Message "Python is not installed. Please install Python before proceeding."
            return $false
        }
        
        # Check if marker is already installed
        $markerInstalled = $false
        $pipListOutput = & python -m pip list 2>&1
        if ($pipListOutput -match "marker") {
            Write-Log -Message "marker library is already installed."
            $markerInstalled = $true
        }
        
        # Install marker using pip if not already installed
        if (-not $markerInstalled) {
            Write-Log -Message "Installing marker library..."
            & python -m pip install marker
            
            if ($LASTEXITCODE -ne 0) {
                Write-Log -Level "ERROR" -Message "Failed to install marker library. Please install it manually using: python -m pip install marker"
                return $false
            }
            
            Write-Log -Message "marker library installed successfully."
        }
        
        return $true
    }
    catch {
        Write-Log -Level "ERROR" -Message "Error installing marker library: $_"
        return $false
    }
}

# Function to convert PDF to Markdown and TXT while preserving directory structure
function Convert-PdfToMarkdownAndTxt {
    param (
        [Parameter(Mandatory=$true)]
        [string]$PdfFile,
        
        [Parameter(Mandatory=$true)]
        [string]$SourceDir,
        
        [Parameter(Mandatory=$true)]
        [string]$OutputDir
    )
    
    try {
        # Get relative path from source directory
        $relativePath = (Get-Item $PdfFile).DirectoryName.Substring($SourceDir.Length)
        if ($relativePath.StartsWith('\')) {
            $relativePath = $relativePath.Substring(1)
        }
        
        # Create the corresponding output directory structure
        $outputSubDir = Join-Path -Path $OutputDir -ChildPath $relativePath
        if (-not [string]::IsNullOrEmpty($relativePath) -and -not (Test-Path -Path $outputSubDir)) {
            New-Item -Path $outputSubDir -ItemType Directory -Force | Out-Null
            Write-Log -Message "Created output subdirectory: $outputSubDir"
        }
        
        $fileName = [System.IO.Path]::GetFileNameWithoutExtension($PdfFile)
        $mdOutputPath = Join-Path -Path $outputSubDir -ChildPath "$fileName.md"
        
        # Convert to Markdown using Python marker library
        Write-Log -Message "Converting $PdfFile to Markdown using marker library..."
        $pythonScript = @"
import sys
import os
import time
from marker.converters.pdf import PdfConverter
from marker.models import create_model_dict
from marker.config.parser import ConfigParser
from marker.output import text_from_rendered


if __name__ == "__main__":
    try:
        # Load the PDF file
        pdf_file = '$($PdfFile.Replace("\", "\\"))'
        md_output = '$($mdOutputPath.Replace("\", "\\"))'
    
        # Initialize the converter
        converter = PdfConverter(
            artifact_dict=create_model_dict(),
        )
    
        # Convert the PDF
        print(f"Processing {pdf_file}...")

        rendered = converter(pdf_file)
        
        # Save as Markdown
        print(f"Saving Markdown to {md_output}...")
        with open(md_output, 'w', encoding='utf-8') as f:
            f.write(rendered.markdown)
    
        # Verify the output files were created
        if os.path.exists(md_output):
            md_size = os.path.getsize(md_output)
            print(f"Conversion completed successfully.")
            print(f"Created Markdown file: {md_output} ({md_size} bytes)")
            sys.exit(0)
        else:
            missing = []
            if not os.path.exists(md_output):
                missing.append("Markdown file")
            print(f"Error: {', '.join(missing)} not created.")
            sys.exit(1)

    except Exception as e:
            print(f"Error during conversion: {str(e)}")
            sys.exit(1)
"@


        # Save the Python script to a temporary file
        $scriptPath = [System.IO.Path]::GetTempFileName() + ".py"
        $pythonScript | Out-File -FilePath $scriptPath -Encoding UTF8
        
        # Execute the Python script
        $result = & python $scriptPath 2>&1
        $exitCode = $LASTEXITCODE
        
        # Remove temporary script file
        Remove-Item -Path $scriptPath -Force
        
        # Output the result from the Python script
        foreach ($line in $result) {
            Write-Log -Message $line
        }
        
        if ($exitCode -ne 0) {
            Write-Log -Level "ERROR" -Message "Python marker conversion failed for $PdfFile"
            return $false
        }
        
        # Verify the output files exist
        if (-not (Test-Path -Path $mdOutputPath)) {
            Write-Log -Level "ERROR" -Message "Output files were not created successfully for $PdfFile"
            return $false
        }
        
        Write-Log -Message "Conversion completed for $PdfFile"
        return $true
    }
    catch {
        Write-Log -Level "ERROR" -Message "Error converting $PdfFile : $_"
        return $false
    }
}

# Function to process all PDF files in the source directory and subdirectories
function Process-PdfFiles {
    param (
        [Parameter(Mandatory=$true)]
        [string]$SourceDir,
        
        [Parameter(Mandatory=$true)]
        [string]$OutputDir
    )
    
    # Ensure directories exist
    if (-not (Test-Path -Path $SourceDir)) {
        New-Item -Path $SourceDir -ItemType Directory -Force | Out-Null
        Write-Log -Message "Created source directory: $SourceDir"
    }
    
    if (-not (Test-Path -Path $OutputDir)) {
        New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
        Write-Log -Message "Created output directory: $OutputDir"
    }
    
    # Get all PDF files in the source directory and all subdirectories
    $pdfFiles = Get-ChildItem -Path $SourceDir -Filter "*.pdf" -File -Recurse
    
    if ($pdfFiles.Count -eq 0) {
        Write-Log -Message "No PDF files found in $SourceDir or its subdirectories"
        return 0
    }
    
    Write-Log -Message "Found $($pdfFiles.Count) PDF files to process."
    $processedCount = 0
    
    # Process each PDF file
    foreach ($pdfFile in $pdfFiles) {
        # Determine the relative path from source directory to build matching output path
        $relativeDir = $pdfFile.DirectoryName.Substring($SourceDir.Length)
        if ($relativeDir.StartsWith('\')) {
            $relativeDir = $relativeDir.Substring(1)
        }
        
        $outputSubDir = Join-Path -Path $OutputDir -ChildPath $relativeDir
        $processedFileName = Join-Path -Path $outputSubDir -ChildPath "$($pdfFile.BaseName).md"
        
        # Check if file has already been processed
        $isAlreadyProcessed = Test-Path -Path $processedFileName
        
        if ($isAlreadyProcessed) {
            Write-Log -Message "$($pdfFile.FullName) was already processed. Skipping."
            continue
        }
        
        $success = Convert-PdfToMarkdownAndTxt -PdfFile $pdfFile.FullName -SourceDir $SourceDir -OutputDir $OutputDir
        
        if ($success) {
            $processedCount++
            
            if ($RemoveOriginals) {
                # Remove the original PDF file after successful processing
                try {
                    Remove-Item -Path $pdfFile.FullName -Force
                    Write-Log -Message "Removed original file after processing: $($pdfFile.FullName)"
                    
                    # Check if the directory is now empty and remove it if it is (only for subdirectories)
                    if ($pdfFile.DirectoryName -ne $SourceDir) {
                        $remainingFiles = Get-ChildItem -Path $pdfFile.DirectoryName -File -ErrorAction SilentlyContinue
                        $remainingDirs = Get-ChildItem -Path $pdfFile.DirectoryName -Directory -ErrorAction SilentlyContinue
                        
                        if (($null -eq $remainingFiles -or $remainingFiles.Count -eq 0) -and 
                            ($null -eq $remainingDirs -or $remainingDirs.Count -eq 0)) {
                            try {
                                Remove-Item -Path $pdfFile.DirectoryName -Force
                                Write-Log -Message "Removed empty directory: $($pdfFile.DirectoryName)"
                            }
                            catch {
                                Write-Log -Level "ERROR" -Message "Error removing empty directory $($pdfFile.DirectoryName): $_"
                            }
                        }
                    }
                }
                catch {
                    Write-Log -Level "ERROR" -Message "Error removing processed file $($pdfFile.FullName): $_"
                }
            }
        }
    }
    
    return $processedCount
}

# Main function
function Start-Processing {
    try {
        Write-Log -Message "Starting PDF processing script..."
        Write-Log -Message "Source directory: $SourceDirectory"
        Write-Log -Message "Output directory: $OutputDirectory"
        
        if ($WatchMode) {
            Write-Log -Message "Running in watch mode with polling interval: $PollingInterval seconds"
        }
        
        if ($RemoveOriginals) {
            Write-Log -Message "Original PDF files will be removed after processing"
        }
        
        # Install the marker library if needed
        $markerInstalled = Install-MarkerLibrary
        if (-not $markerInstalled) {
            Write-Log -Level "ERROR" -Message "Required marker library could not be installed. Script cannot continue."
            return
        }
        
        if ($WatchMode) {
            # Watch mode - continuously monitor for new files
            Write-Log -Message "Watch mode enabled. Press Ctrl+C to stop."
            
            try {
                while ($true) {
                    $processedCount = Process-PdfFiles -SourceDir $SourceDirectory -OutputDir $OutputDirectory
                    if ($processedCount -gt 0) {
                        Write-Log -Message "Processed $processedCount files in this cycle."
                    }
                    
                    Write-Log -Message "Waiting $PollingInterval seconds for next check..." -Level "DEBUG"
                    Start-Sleep -Seconds $PollingInterval
                }
            }
            catch [System.Management.Automation.PipelineStoppedException] {
                # This catches Ctrl+C
                Write-Log -Message "Watch mode stopped by user."
            }
        }
        else {
            # One-time processing
            $processedCount = Process-PdfFiles -SourceDir $SourceDirectory -OutputDir $OutputDirectory
            Write-Log -Message "Processing complete. Processed $processedCount files."
        }
    }
    catch {
        Write-Log -Level "ERROR" -Message "Error in main processing: $_"
    }
}

# Start processing
Start-Processing