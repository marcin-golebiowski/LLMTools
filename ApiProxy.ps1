# ApiProxy.ps1
# REST API proxy that provides /api/chat endpoint
# Uses ChromaDB for vector search to find relevant context
# Forwards enhanced prompts to Ollama REST API

#Requires -Version 7.0
#Requires -Modules Microsoft.PowerShell.Management, Microsoft.PowerShell.Utility

param (
    [Parameter(Mandatory=$false)]
    [string]$ListenAddress = "localhost",
    
    [Parameter(Mandatory=$false)]
    [int]$Port = 8081,
    
    [Parameter(Mandatory=$false)]
    [string]$ChromaDbPath = "./chroma_db",
    
    [Parameter(Mandatory=$false)]
    [string]$OllamaUrl = "http://localhost:11434",
    
    [Parameter(Mandatory=$false)]
    [string]$EmbeddingModel = "mxbai-embed-large:latest",
    
    [Parameter(Mandatory=$false)]
    [int]$RelevanceThreshold = 0.75,
    
    [Parameter(Mandatory=$false)]
    [int]$MaxContextDocs = 5,
    
    [Parameter(Mandatory=$false)]
    [switch]$UseHttps
)

# Set up logging
$Global:ApiLogFile = Join-Path -Path $PSScriptRoot -ChildPath "api-proxy.log"
$pythonHelperPath = Join-Path -Path $PSScriptRoot -ChildPath "api_proxy_helper.py"

function Write-ApiLog {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [string]$Level = "INFO",

        [Parameter(Mandatory=$false)]
        [string]$ForegroundColor = "Black"
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
    $logDir = Split-Path -Path $Global:ApiLogFile -Parent
    if (-not (Test-Path -Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    
    # Write to log file
    Add-Content -Path $Global:ApiLogFile -Value $logMessage
}

# Check if Python is installed
try {
    $pythonVersion = pwsh.exe --version
    Write-ApiLog -Message "Found Python: $pythonVersion" -ForegroundColor Green
}
catch {
    Write-ApiLog -Message "Python not found. Please install Python 3.8+ to use this script. $_" -Level "ERROR"
    exit 1
}

# Install required packages if not already installed
function Ensure-Package {
    param([string]$PackageName)
    
    $installed = pwsh.exe -c "try: 
        import $PackageName
        print('installed')
    except ImportError: 
        print('not installed')" 2>$null
    
    if ($installed -ne "installed") {
        Write-Host "Installing $PackageName..." -ForegroundColor Yellow
        python -m pip install $PackageName
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to install $PackageName. Please install it manually with 'pip install $PackageName'" -ForegroundColor Red
            exit 1
        }
        Write-Host "$PackageName installed successfully." -ForegroundColor Green
    }
    else {
        Write-Host "$PackageName is already installed." -ForegroundColor Green
    }
}

Write-ApiLog -Message "Checking for required Python packages..." -Level "INFO"
Ensure-Package "chromadb"
Ensure-Package "requests"
Ensure-Package "numpy"

# Check if ChromaDB path exists
if (-not (Test-Path -Path $ChromaDbPath)) {
    Write-ApiLog -Message "ChromaDB path does not exist: $ChromaDbPath" -Level "WARNING"
    Write-ApiLog -Message "Creating directory: $ChromaDbPath" -Level "INFO"
    New-Item -Path $ChromaDbPath -ItemType Directory -Force | Out-Null
    
    Write-ApiLog -Message "WARNING: ChromaDB is empty. You should run CreateChromaEmbeddings.ps1 to populate it." -Level "WARNING"
}

# Check if Ollama is running
Write-ApiLog -Message "Checking if Ollama is running at $OllamaUrl..." -Level "INFO"
try {
    $ollamaStatus = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -Method Get -ErrorAction Stop
    Write-ApiLog -Message "Ollama is running." -Level "INFO"
    
    # Check if embedding model is available
    $modelFound = $false
    foreach ($model in $ollamaStatus.models) {
        if ($model.name -eq $EmbeddingModel) {
            $modelFound = $true
            break
        }
    }
    
    if (-not $modelFound) {
        Write-ApiLog -Message "WARNING: Embedding model '$EmbeddingModel' not found in Ollama." -Level "WARNING"
        Write-ApiLog -Message "Available models: $($ollamaStatus.models.name -join ', ')" -Level "INFO"
    }
}
catch {
    Write-ApiLog -Message "Ollama is not running or not accessible at $OllamaUrl" -Level "ERROR"
    Write-ApiLog -Message "Please ensure Ollama is running before proceeding." -Level "ERROR"
    Write-ApiLog -Message "You can download Ollama from https://ollama.ai/" -Level "INFO"
    exit 1
}

# Function to query ChromaDB for relevant documents
function Get-RelevantDocuments {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Query,
        
        [Parameter(Mandatory=$false)]
        [int]$MaxResults = $MaxContextDocs,
        
        [Parameter(Mandatory=$false)]
        [double]$Threshold = $RelevanceThreshold
    )
    
    try {
        $pythonCmd = "python.exe ""$pythonHelperPath"" query ""$Query"" ""$ChromaDbPath"" ""$EmbeddingModel"" ""$OllamaUrl"" $MaxResults $Threshold"
        $resultJson = Invoke-Expression $pythonCmd
        $result = $resultJson | ConvertFrom-Json
        
        if ($result.PSObject.Properties.Name -contains "error") {
            Write-ApiLog -Message "Error querying ChromaDB: $($result.error)" -Level "ERROR"
            return @{
                success = $false
                error = $result.error
                results = @()
            }
        }
        
        return @{
            success = $true
            results = $result.results
            count = $result.count
        }
    }
    catch {
        Write-ApiLog -Message "Exception querying ChromaDB: $_" -Level "ERROR"
        return @{
            success = $false
            error = $_.ToString()
            results = @()
        }
    }
}

# Function to prepare context from relevant documents
function Format-RelevantContextForOllama {
    param (
        [Parameter(Mandatory=$true)]
        [object]$Documents
    )
    
    $contextText = "I'll help answer your questions based on the following information:`n`n"
    
    foreach ($doc in $Documents) {
        $source = $doc.metadata.source
        $fileName = Split-Path -Path $source -Leaf
        $lineRange = $doc.metadata.line_range
        
        $contextText += "---`n"
        $contextText += "Source: $fileName (lines $lineRange)`n"
        $contextText += "Content:`n$($doc.document)`n`n"
    }
    
    return $contextText
}

# Function to get list of available models from Ollama
function Get-OllamaModels {
    param (
        [Parameter(Mandatory=$false)]
        [bool]$IncludeDetails = $false
    )
    
    try {
        $pythonCmd = "python.exe ""$pythonHelperPath"" models ""$OllamaUrl"" ""$IncludeDetails"""
        $resultJson = Invoke-Expression $pythonCmd
        Write-Host $resultJson
        $result = $resultJson | ConvertFrom-Json
        
        if ($result.PSObject.Properties.Name -contains "error") {
            Write-ApiLog -Message "Error getting models from Ollama: $($result.error)" -Level "ERROR"
            return @{
                success = $false
                error = $result.error
                models = @()
            }
        }
        
        return @{
            success = $true
            models = $result.models
            count = $result.count
        }
    }
    catch {
        Write-ApiLog -Message "Exception getting models from Ollama: $_" -Level "ERROR"
        return @{
            success = $false
            error = $_.ToString()
            models = @()
        }
    }
}

# Function to send enhanced prompt to Ollama
function Send-ChatToOllama {
    param (
        [Parameter(Mandatory=$true)]
        [object]$Messages,
        
        [Parameter(Mandatory=$true)]
        [string]$Model,
        
        [Parameter(Mandatory=$false)]
        [object]$Context = $null
    )
    
    try {
        $messagesJson = $Messages | ConvertTo-Json -Depth 10 -Compress
        $contextJson = if ($null -ne $Context) { $Context | ConvertTo-Json -Compress } else { "null" }
        
        $pythonCmd = "python.exe ""$pythonHelperPath"" chat '$messagesJson' ""$Model"" '$contextJson' ""$OllamaUrl"""
        $resultJson = Invoke-Expression $pythonCmd
        $result = $resultJson | ConvertFrom-Json
        
        if ($result.PSObject.Properties.Name -contains "error") {
            Write-ApiLog -Message "Error sending chat to Ollama: $($result.error)" -Level "ERROR"
            return @{
                success = $false
                error = $result.error
            }
        }
        
        return @{
            success = $true
            result = $result
        }
    }
    catch {
        Write-ApiLog -Message "Exception sending chat to Ollama: $_" -Level "ERROR"
        return @{
            success = $false
            error = $_.ToString()
        }
    }
}

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
    
    Write-ApiLog -Message "API proxy started at $prefix" -Level "INFO"
    Write-ApiLog -Message "ChromaDB path: $ChromaDbPath" -Level "INFO"
    Write-ApiLog -Message "Ollama URL: $OllamaUrl" -Level "INFO"
    Write-ApiLog -Message "Embedding model: $EmbeddingModel" -Level "INFO"
    Write-ApiLog -Message "Relevance threshold: $RelevanceThreshold" -Level "INFO"
    Write-ApiLog -Message "Max context documents: $MaxContextDocs" -Level "INFO"
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
                            message = "API proxy running"
                            routes = @(
                "/api/chat - POST: Chat with context augmentation",
                "/api/search - POST: Search for relevant documents",
                "/api/models - GET: Get list of available models",
                "/status - GET: Get API proxy status"
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
                
                # --- Models endpoint ---
                "/api/models" {
                    if ($method -eq "GET") {
                        # Extract parameters
                        $includeDetails = $request.QueryString["include_details"] -eq "true"
                        
                        # Get models
                        $modelsResult = Get-OllamaModels -IncludeDetails $includeDetails
                        
                        if ($modelsResult.success) {
                            $responseBody = @{
                                models = $modelsResult.models
                                count = $modelsResult.count
                            }
                        }
                        else {
                            $statusCode = 500
                            $responseBody = @{
                                error = "Models error"
                                message = $modelsResult.error
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
                
                # --- Status endpoint ---
                "/status" {
                    if ($method -eq "GET") {
                        $responseBody = @{
                            status = "ok"
                            chromaDbPath = $ChromaDbPath
                            ollamaUrl = $OllamaUrl
                            embeddingModel = $EmbeddingModel
                            relevanceThreshold = $RelevanceThreshold
                            maxContextDocs = $MaxContextDocs
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
                
                # --- Search endpoint ---
                "/api/search" {
                    if ($method -eq "POST") {
                        # Validate required parameters
                        if ($null -eq $requestBody -or $null -eq $requestBody.query) {
                            $statusCode = 400
                            $responseBody = @{
                                error = "Bad request"
                                message = "Required parameter missing: query"
                            }
                        }
                        else {
                            # Extract parameters
                            $query = $requestBody.query
                            $maxResults = if ($null -ne $requestBody.max_results) { $requestBody.max_results } else { $MaxContextDocs }
                            $threshold = if ($null -ne $requestBody.threshold) { $requestBody.threshold } else { $RelevanceThreshold }
                            
                            # Get relevant documents
                            $searchResult = Get-RelevantDocuments -Query $query -MaxResults $maxResults -Threshold $threshold
                            
                            if ($searchResult.success) {
                                $responseBody = @{
                                    success = $true
                                    query = $query
                                    results = $searchResult.results
                                    count = $searchResult.count
                                }
                            }
                            else {
                                $statusCode = 500
                                $responseBody = @{
                                    error = "Search error"
                                    message = $searchResult.error
                                }
                            }
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
                
                # --- Chat endpoint ---
                "/api/chat" {
                    if ($method -eq "POST") {
                        # Validate required parameters
                        if ($null -eq $requestBody -or $null -eq $requestBody.messages) {
                            $statusCode = 400
                            $responseBody = @{
                                error = "Bad request"
                                message = "Required parameter missing: messages"
                            }
                        }
                        else {
                            # Extract parameters
                            $messages = $requestBody.messages
                            $model = if ($null -ne $requestBody.model) { $requestBody.model } else { "llama3" }
                            $maxResults = if ($null -ne $requestBody.max_context_docs) { $requestBody.max_context_docs } else { $MaxContextDocs }
                            $threshold = if ($null -ne $requestBody.threshold) { $requestBody.threshold } else { $RelevanceThreshold }
                            $enhanceContext = if ($null -ne $requestBody.enhance_context) { $requestBody.enhance_context } else { $true }
                            
                            # Get the latest user message for context search
                            $latestUserMessage = $null
                            for ($i = $messages.Count - 1; $i -ge 0; $i--) {
                                if ($messages[$i].role -eq "user") {
                                    $latestUserMessage = $messages[$i].content
                                    break
                                }
                            }
                            
                            # Get relevant documents if we should enhance context
                            $contextDocuments = @()
                            $rawOllamaContext = $null
                            
                            if ($enhanceContext -and $null -ne $latestUserMessage) {
                                $searchResult = Get-RelevantDocuments -Query $latestUserMessage -MaxResults $maxResults -Threshold $threshold
                                
                                if ($searchResult.success -and $searchResult.count -gt 0) {
                                    $contextDocuments = $searchResult.results
                                    
                                    # Prepare context for Ollama
                                    # For raw token format (experimental)
                                    $rawContext = ""
                                    foreach ($doc in $contextDocuments) {
                                        $rawContext += $doc.document + "`n`n"
                                    }
                                    
                                    # For displaying to the user
                                    $formattedContext = Format-RelevantContextForOllama -Documents $contextDocuments
                                    
                                    # Extract possible integer context from the requestBody
                                    if ($requestBody.PSObject.Properties.Name -contains "context" -and $requestBody.context -is [int]) {
                                        $rawOllamaContext = $requestBody.context
                                    }
                                }
                            }
                            
                            # Send chat to Ollama
                            $chatResult = $null
                            
                            # If we found relevant documents, add context to the system message
                            if ($contextDocuments.Count -gt 0) {
                                # Make a copy of the original messages
                                $enhancedMessages = @()
                                $hasSystemMessage = $false
                                
                                foreach ($msg in $messages) {
                                    if ($msg.role -eq "system") {
                                        # Enhance the system message with context
                                        $enhancedMessage = @{
                                            role = "system"
                                            content = "$($msg.content)`n`n$formattedContext"
                                        }
                                        $enhancedMessages += $enhancedMessage
                                        $hasSystemMessage = $true
                                    }
                                    else {
                                        # Keep other messages as they are
                                        $enhancedMessages += $msg
                                    }
                                }
                                
                                # If there's no system message, add one with the context
                                if (-not $hasSystemMessage) {
                                    $enhancedMessages = @(@{
                                        role = "system"
                                        content = $formattedContext
                                    }) + $enhancedMessages
                                }
                                
                                $chatResult = Send-ChatToOllama -Messages $enhancedMessages -Model $model -Context $rawOllamaContext
                            }
                            else {
                                # No relevant documents, send as is
                                $chatResult = Send-ChatToOllama -Messages $messages -Model $model -Context $rawOllamaContext
                            }
                            
                            if ($chatResult.success) {
                                # Add some metadata about the context to the response
                                $responseBody = $chatResult.result
                                $responseBody | Add-Member -MemberType NoteProperty -Name "context_count" -Value $contextDocuments.Count
                                
                                if ($contextDocuments.Count -gt 0) {
                                    # Add simplified context information
                                    $simplifiedContext = @()
                                    foreach ($doc in $contextDocuments) {
                                        $simplifiedContext += @{
                                            source = Split-Path -Path $doc.metadata.source -Leaf
                                            line_range = $doc.metadata.line_range
                                            similarity = $doc.similarity
                                        }
                                    }
                                    $responseBody | Add-Member -MemberType NoteProperty -Name "context_info" -Value $simplifiedContext
                                }
                            }
                            else {
                                $statusCode = 500
                                $responseBody = @{
                                    error = "Chat error"
                                    message = $chatResult.error
                                }
                            }
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
    Write-ApiLog -Message "Fatal error in API proxy server: $_" -Level "ERROR"
}
finally {
    # Clean up
    if ($null -ne $listener -and $listener.IsListening) {
        $listener.Stop()
        $listener.Close()
    }
    
    Write-ApiLog -Message "API proxy server stopped" -Level "INFO"
}
