param (
    [Parameter(Mandatory = $true)]
    [string]$EventDataPath
)

# Read the event data
$eventData = Get-Content -Path $EventDataPath | ConvertFrom-Json

# Now you can use $eventData.ChangeType and $eventData.FilePath in your script
Write-Host "Processing file: $($eventData.FilePath) (Event: $($eventData.ChangeType))"

# Your custom processing logic here...


Add-Content -Path "loghandler.txt" -Value 
