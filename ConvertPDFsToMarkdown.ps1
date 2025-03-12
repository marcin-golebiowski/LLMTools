# PDF to Markdown/TXT Processor Script
# This script processes PDF files from a directory and converts them to Markdown and TXT formats
# using multiple OCR tool options: marker, tesseract, ocrmypdf, or pymupdf

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
    [switch]$RemoveOriginals,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("marker", "tesseract", "ocrmypdf", "pymupdf")]
    [string]$OcrTool = "marker"
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

# Function to install the required OCR library based on the selected tool
function Install-OcrLibrary {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Tool
    )
    
    switch ($Tool) {
        "marker" {
            return Install-MarkerLibrary
        }
        "tesseract" {
            return Install-TesseractLibrary
        }
        "ocrmypdf" {
            return Install-OcrMyPdfLibrary
        }
        "pymupdf" {
            return Install-PyMuPdfLibrary
        }
        default {
            Write-Log -Level "ERROR" -Message "Unsupported OCR tool: $Tool"
            return $false
        }
    }
}

# Function to install the marker library
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

# Function to install the Tesseract OCR library
function Install-TesseractLibrary {
    try {
        # Check if Python is installed
        if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
            Write-Log -Level "ERROR" -Message "Python is not installed. Please install Python before proceeding."
            return $false
        }
        
        # Check if tesseract-ocr is installed
        $tesseractInstalled = $false
        try {
            $tesseractCheck = & tesseract --version 2>&1
            if ($tesseractCheck -match "tesseract") {
                Write-Log -Message "Tesseract OCR is already installed."
                $tesseractInstalled = $true
            }
        }
        catch {
            $tesseractInstalled = $false
        }
        
        if (-not $tesseractInstalled) {
            Write-Log -Level "WARNING" -Message "Tesseract OCR needs to be installed separately. Please download and install from: https://github.com/UB-Mannheim/tesseract/wiki"
            Write-Log -Message "Attempting to continue with Python libraries installation..."
        }
        
        # Check if pytesseract and related libraries are installed
        $pytesseractInstalled = $false
        $pipListOutput = & python -m pip list 2>&1
        if ($pipListOutput -match "pytesseract" -and $pipListOutput -match "Pillow" -and $pipListOutput -match "pdf2image") {
            Write-Log -Message "Required Python libraries for Tesseract are already installed."
            $pytesseractInstalled = $true
        }
        
        # Install required Python libraries if not already installed
        if (-not $pytesseractInstalled) {
            Write-Log -Message "Installing required Python libraries for Tesseract OCR..."
            & python -m pip install pytesseract Pillow pdf2image markdown
            
            if ($LASTEXITCODE -ne 0) {
                Write-Log -Level "ERROR" -Message "Failed to install required Python libraries for Tesseract OCR."
                return $false
            }
            
            Write-Log -Message "Required Python libraries for Tesseract OCR installed successfully."
        }
        
        # Check for poppler for pdf2image
        $popplerInstalled = $false
        try {
            $popplerCheck = & pdftoppm -v 2>&1
            if ($popplerCheck -match "pdftoppm") {
                Write-Log -Message "Poppler is already installed."
                $popplerInstalled = $true
            }
        }
        catch {
            $popplerInstalled = $false
        }
        
        if (-not $popplerInstalled) {
            Write-Log -Level "WARNING" -Message "Poppler is not installed. This is required for pdf2image to convert PDFs. Please download and install from: https://github.com/oschwartz10612/poppler-windows/releases/"
            Write-Log -Level "WARNING" -Message "After installing, ensure the bin directory is added to your PATH environment variable."
        }
        
        return $true
    }
    catch {
        Write-Log -Level "ERROR" -Message "Error installing Tesseract OCR libraries: $_"
        return $false
    }
}

# Function to install OCRmyPDF library
function Install-OcrMyPdfLibrary {
    try {
        # Check if Python is installed
        if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
            Write-Log -Level "ERROR" -Message "Python is not installed. Please install Python before proceeding."
            return $false
        }
        
        # Check if tesseract-ocr is installed (required by OCRmyPDF)
        $tesseractInstalled = $false
        try {
            $tesseractCheck = & tesseract --version 2>&1
            if ($tesseractCheck -match "tesseract") {
                Write-Log -Message "Tesseract OCR is already installed."
                $tesseractInstalled = $true
            }
        }
        catch {
            $tesseractInstalled = $false
        }
        
        if (-not $tesseractInstalled) {
            Write-Log -Level "WARNING" -Message "Tesseract OCR needs to be installed separately. Please download and install from: https://github.com/UB-Mannheim/tesseract/wiki"
            Write-Log -Message "Attempting to continue with OCRmyPDF installation..."
        }
        
        # Check if OCRmyPDF is installed
        $ocrmypdfInstalled = $false
        $pipListOutput = & python -m pip list 2>&1
        if ($pipListOutput -match "ocrmypdf") {
            Write-Log -Message "OCRmyPDF is already installed."
            $ocrmypdfInstalled = $true
        }
        
        # Install OCRmyPDF if not already installed
        if (-not $ocrmypdfInstalled) {
            Write-Log -Message "Installing OCRmyPDF..."
            & python -m pip install ocrmypdf markdown
            
            if ($LASTEXITCODE -ne 0) {
                Write-Log -Level "ERROR" -Message "Failed to install OCRmyPDF. Please install it manually using: python -m pip install ocrmypdf"
                return $false
            }
            
            Write-Log -Message "OCRmyPDF installed successfully."
            
            # Check for Ghostscript (required by OCRmyPDF)
            $gsInstalled = $false
            try {
                $gsCheck = & gswin64c -v 2>&1
                if ($gsCheck -match "Ghostscript") {
                    Write-Log -Message "Ghostscript is already installed."
                    $gsInstalled = $true
                }
            }
            catch {
                $gsInstalled = $false
            }
            
            if (-not $gsInstalled) {
                Write-Log -Level "WARNING" -Message "Ghostscript is not installed. This is required by OCRmyPDF. Please download and install from: https://ghostscript.com/releases/gsdnld.html"
            }
        }
        
        return $true
    }
    catch {
        Write-Log -Level "ERROR" -Message "Error installing OCRmyPDF: $_"
        return $false
    }
}

# Function to install PyMuPDF library
function Install-PyMuPdfLibrary {
    try {
        # Check if Python is installed
        if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
            Write-Log -Level "ERROR" -Message "Python is not installed. Please install Python before proceeding."
            return $false
        }
        
        # Check if PyMuPDF is already installed
        $pymupdfInstalled = $false
        $pipListOutput = & python -m pip list 2>&1
        if ($pipListOutput -match "PyMuPDF") {
            Write-Log -Message "PyMuPDF is already installed."
            $pymupdfInstalled = $true
        }
        
        # Install PyMuPDF using pip if not already installed
        if (-not $pymupdfInstalled) {
            Write-Log -Message "Installing PyMuPDF..."
            & python -m pip install PyMuPDF markdown
            
            if ($LASTEXITCODE -ne 0) {
                Write-Log -Level "ERROR" -Message "Failed to install PyMuPDF. Please install it manually using: python -m pip install PyMuPDF"
                return $false
            }
            
            Write-Log -Message "PyMuPDF installed successfully."
        }
        
        return $true
    }
    catch {
        Write-Log -Level "ERROR" -Message "Error installing PyMuPDF: $_"
        return $false
    }
}

# Unified function to convert PDF to Markdown and TXT while preserving directory structure
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
        
        # Choose conversion method based on selected OCR tool
        Write-Log -Message "Converting $PdfFile to Markdown using $OcrTool..."
        
        switch ($OcrTool) {
            "marker" {
                $success = Convert-PdfWithMarker -PdfFile $PdfFile -MdOutputPath $mdOutputPath
            }
            "tesseract" {
                $success = Convert-PdfWithTesseract -PdfFile $PdfFile -MdOutputPath $mdOutputPath
            }
            "ocrmypdf" {
                $success = Convert-PdfWithOcrMyPdf -PdfFile $PdfFile -MdOutputPath $mdOutputPath
            }
            "pymupdf" {
                $success = Convert-PdfWithPyMuPdf -PdfFile $PdfFile -MdOutputPath $mdOutputPath
            }
            default {
                Write-Log -Level "ERROR" -Message "Unsupported OCR tool: $OcrTool"
                return $false
            }
        }
        
        if (-not $success) {
            Write-Log -Level "ERROR" -Message "Conversion failed for $PdfFile with $OcrTool"
            return $false
        }
        
        # Verify the output files exist
        if (-not (Test-Path -Path $mdOutputPath)) {
            Write-Log -Level "ERROR" -Message "Output files were not created successfully for $PdfFile"
            return $false
        }
        
        Write-Log -Message "Conversion completed for $PdfFile using $OcrTool"
        return $true
    }
    catch {
        Write-Log -Level "ERROR" -Message "Error converting $PdfFile : $_"
        return $false
    }
}

# Convert PDF using Marker library
function Convert-PdfWithMarker {
    param (
        [Parameter(Mandatory=$true)]
        [string]$PdfFile,
        
        [Parameter(Mandatory=$true)]
        [string]$MdOutputPath
    )
    
    try {
        # Convert to Markdown using Python marker library
        $pythonScript = @"
import sys
import os
from marker.converters.pdf import PdfConverter
from marker.models import create_model_dict

if __name__ == "__main__":
    try:
        # Load the PDF file
        pdf_file = '$($PdfFile.Replace("\", "\\"))'
        md_output = '$($MdOutputPath.Replace("\", "\\"))'
    
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
        
        return ($exitCode -eq 0)
    }
    catch {
        Write-Log -Level "ERROR" -Message "Error using Marker OCR: $_"
        return $false
    }
}

# Convert PDF using Tesseract OCR
function Convert-PdfWithTesseract {
    param (
        [Parameter(Mandatory=$true)]
        [string]$PdfFile,
        
        [Parameter(Mandatory=$true)]
        [string]$MdOutputPath
    )
    
    try {
        # Convert to Markdown using pytesseract
        $pythonScript = @"
import sys
import os
import pytesseract
from pdf2image import convert_from_path
from PIL import Image
import tempfile
import shutil

if __name__ == "__main__":
    try:
        # Load the PDF file
        pdf_file = '$($PdfFile.Replace("\", "\\"))'
        md_output = '$($MdOutputPath.Replace("\", "\\"))'
        temp_dir = tempfile.mkdtemp()
        
        try:
            print(f"Processing {pdf_file}...")
            
            # Convert PDF to images
            print("Converting PDF to images...")
            pages = convert_from_path(pdf_file, 300)
            
            # Process each page
            full_text = []
            for i, page in enumerate(pages):
                print(f"Processing page {i+1}/{len(pages)}...")
                # Save page as temporary image
                img_path = os.path.join(temp_dir, f"page_{i+1}.png")
                page.save(img_path, "PNG")
                
                # Extract text using tesseract
                text = pytesseract.image_to_string(Image.open(img_path))
                full_text.append(text)
            
            # Combine text and save as Markdown
            print(f"Saving Markdown to {md_output}...")
            with open(md_output, 'w', encoding='utf-8') as f:
                # Add page breaks and headers
                for i, text in enumerate(full_text):
                    if i > 0:
                        f.write("\\n\\n---\\n\\n")  # Page break in Markdown
                    
                    f.write(f"# Page {i+1}\\n\\n")
                    f.write(text)
            
            # Verify the output file was created
            if os.path.exists(md_output):
                md_size = os.path.getsize(md_output)
                print(f"Conversion completed successfully.")
                print(f"Created Markdown file: {md_output} ({md_size} bytes)")
                sys.exit(0)
            else:
                print(f"Error: Markdown file not created.")
                sys.exit(1)
                
        finally:
            # Clean up temporary directory
            shutil.rmtree(temp_dir)

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
        
        return ($exitCode -eq 0)
    }
    catch {
        Write-Log -Level "ERROR" -Message "Error using Tesseract OCR: $_"
        return $false
    }
}

# Convert PDF using OCRmyPDF
function Convert-PdfWithOcrMyPdf {
    param (
        [Parameter(Mandatory=$true)]
        [string]$PdfFile,
        
        [Parameter(Mandatory=$true)]
        [string]$MdOutputPath
    )
    
    try {
        # Convert to Markdown using OCRmyPDF
        $pythonScript = @"
import sys
import os
import tempfile
import ocrmypdf
import fitz  # PyMuPDF

if __name__ == "__main__":
    try:
        # Load the PDF file
        pdf_file = '$($PdfFile.Replace("\", "\\"))'
        md_output = '$($MdOutputPath.Replace("\", "\\"))'
        
        # Create a temporary file for the OCR'd PDF
        fd, temp_pdf = tempfile.mkstemp(suffix='.pdf')
        os.close(fd)
        
        try:
            print(f"Processing {pdf_file} with OCRmyPDF...")
            
            # Run OCR on the PDF
            ocrmypdf.ocr(pdf_file, temp_pdf, force_ocr=True)
            
            # Extract text from the OCR'd PDF using PyMuPDF
            print("Extracting text from OCR'd PDF...")
            doc = fitz.open(temp_pdf)
            full_text = []
            
            for page_num in range(len(doc)):
                page = doc.load_page(page_num)
                text = page.get_text()
                full_text.append(text)
            
            doc.close()
            
            # Save as Markdown
            print(f"Saving Markdown to {md_output}...")
            with open(md_output, 'w', encoding='utf-8') as f:
                # Add page breaks and headers
                for i, text in enumerate(full_text):
                    if i > 0:
                        f.write("\\n\\n---\\n\\n")  # Page break in Markdown
                    
                    f.write(f"# Page {i+1}\\n\\n")
                    f.write(text)
            
            # Verify the output file was created
            if os.path.exists(md_output):
                md_size = os.path.getsize(md_output)
                print(f"Conversion completed successfully.")
                print(f"Created Markdown file: {md_output} ({md_size} bytes)")
                sys.exit(0)
            else:
                print(f"Error: Markdown file not created.")
                sys.exit(1)
        
        finally:
            # Clean up temporary file
            if os.path.exists(temp_pdf):
                os.unlink(temp_pdf)

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
        
        return ($exitCode -eq 0)
    }
    catch {
        Write-Log -Level "ERROR" -Message "Error using OCRmyPDF: $_"
        return $false
    }
}

# Convert PDF using PyMuPDF
function Convert-PdfWithPyMuPdf {
    param (
        [Parameter(Mandatory=$true)]
        [string]$PdfFile,
        
        [Parameter(Mandatory=$true)]
        [string]$MdOutputPath
    )
    
    try {
        # Convert to Markdown using PyMuPDF
        $pythonScript = @"
import sys
import os
import fitz  # PyMuPDF

if __name__ == "__main__":
    try:
        # Load the PDF file
        pdf_file = '$($PdfFile.Replace("\", "\\"))'
        md_output = '$($MdOutputPath.Replace("\", "\\"))'
        
        print(f"Processing {pdf_file} with PyMuPDF...")
        
        # Extract text from the PDF
        doc = fitz.open(pdf_file)
        full_text = []
        
        for page_num in range(len(doc)):
            page = doc.load_page(page_num)
            
            # Get text
            text = page.get_text()
            
            # Process blocks for better structure
            blocks = page.get_text("blocks")
            structured_text = ""
            
            # Sort blocks by y-coordinate to maintain reading order
            blocks.sort(key=lambda b: b[1])  # Sort by y1 (top)
            
            for block in blocks:
                # block[4] is the text content
                structured_text += block[4] + "\\n\\n"
            
            full_text.append(structured_text if structured_text.strip() else text)
        
        doc.close()
        
        # Save as Markdown
        print(f"Saving Markdown to {md_output}...")
        with open(md_output, 'w', encoding='utf-8') as f:
            # Add page breaks and headers
            for i, text in enumerate(full_text):
                if i > 0:
                    f.write("\\n\\n---\\n\\n")  # Page break in Markdown
                
                f.write(f"# Page {i+1}\\n\\n")
                f.write(text)
        
        # Verify the output file was created
        if os.path.exists(md_output):
            md_size = os.path.getsize(md_output)
            print(f"Conversion completed successfully.")
            print(f"Created Markdown file: {md_output} ({md_size} bytes)")
            sys.exit(0)
        else:
            print(f"Error: Markdown file not created.")
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
        
        return ($exitCode -eq 0)
    }
    catch {
        Write-Log -Level "ERROR" -Message "Error using PyMuPDF: $_"
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
        Write-Log -Message "Using OCR tool: $OcrTool"
        
        if ($WatchMode) {
            Write-Log -Message "Running in watch mode with polling interval: $PollingInterval seconds"
        }
        
        if ($RemoveOriginals) {
            Write-Log -Message "Original PDF files will be removed after processing"
        }
        
        # Install the required OCR library
        $ocrInstalled = Install-OcrLibrary -Tool $OcrTool
        if (-not $ocrInstalled) {
            Write-Log -Level "ERROR" -Message "Required $OcrTool library could not be installed. Script cannot continue."
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
