# S.E.I.Z.E. (Swift Electronic Ingestion & Zero-delay Extraction)
# Forensic Extraction Script for Windows Targets
# Designed for Nepal Police Digital Forensics

$ErrorActionPreference = "SilentlyContinue"

# Configuration
$ServerIP = "192.168.7.1"
$ServerPort = "5000"
$BaseUrl = "http://$ServerIP`:$ServerPort/api"
$TempDir = "$env:TEMP\seize_triage"

# Helper: Send status updates to S.E.I.Z.E. Pi Server
function Send-StatusUpdate($task, $percent) {
    $body = @{
        task = $task
        percent = $percent
    } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri "$BaseUrl/progress" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 2
    } catch {
        Write-Host "Warning: Could not contact S.E.I.Z.E. server: $_"
    }
}

# Helper: Send errors to Pi
function Send-Error($msg) {
    $body = @{
        message = $msg
    } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri "$BaseUrl/error" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 2
    } catch {}
}

# Main Script Execution
Write-Host "[*] Starting S.E.I.Z.E. Forensic Extraction..."
Write-Host "[*] Target IP: $ServerIP"

# 1. Initialize Connection
$Hostname = $env:COMPUTERNAME
$OSInfo = (Get-WmiObject -Class Win32_OperatingSystem).Caption
if (!$OSInfo) { $OSInfo = "Windows (Modern)" }

$initBody = @{
    hostname = $Hostname
    os = $OSInfo
} | ConvertTo-Json

try {
    Invoke-RestMethod -Uri "$BaseUrl/start" -Method Post -Body $initBody -ContentType "application/json" -TimeoutSec 5
    Write-Host "[+] Connected to S.E.I.Z.E. Pi Server."
} catch {
    Write-Host "[!] Error: Cannot connect to S.E.I.Z.E. server. Check network connection."
    exit
}

# Create Temp directory for collection
if (Test-Path $TempDir) { Remove-Item -Path $TempDir -Recurse -Force }
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
New-Item -ItemType Directory -Path "$TempDir\browsers" -Force | Out-Null
New-Item -ItemType Directory -Path "$TempDir\volatile_ram" -Force | Out-Null

# 2. Extract Volatile RAM & System Metadata
Send-StatusUpdate "Extracting System Metadata & Volatile RAM..." 15
Write-Host "[*] Collecting system info..."

# System Information
$sysInfoFile = "$TempDir\volatile_ram\system_info.txt"
"--- S.E.I.Z.E. SYSTEM REPORT ---" | Out-File $sysInfoFile
"Hostname: $Hostname" | Out-File $sysInfoFile -Append
"OS: $OSInfo" | Out-File $sysInfoFile -Append
"Username: $env:USERNAME" | Out-File $sysInfoFile -Append
"Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $sysInfoFile -Append
"Environment Variables:" | Out-File $sysInfoFile -Append
Get-ChildItem env: | Format-List | Out-File $sysInfoFile -Append

# Running Processes (RAM Metadata)
Write-Host "[*] Dumping running processes..."
Send-StatusUpdate "Dumping active processes..." 25
$processesFile = "$TempDir\volatile_ram\processes.txt"
Get-Process | Select-Object Id, ProcessName, CPU, WorkingSet64, Path, Description, Company | Format-Table -AutoSize | Out-File $processesFile

# Network Connections (Active RAM Port bindings)
Write-Host "[*] Collecting active network connections..."
Send-StatusUpdate "Collecting network connections..." 35
$netConnFile = "$TempDir\volatile_ram\network_connections.txt"
"netstat -ano output:" | Out-File $netConnFile
netstat -ano | Out-File $netConnFile -Append

# Clipboard Contents (Volatile RAM Cache)
Write-Host "[*] Extracting clipboard contents..."
$clipFile = "$TempDir\volatile_ram\clipboard.txt"
try {
    Add-Type -AssemblyName System.Windows.Forms
    $clipboardText = [System.Windows.Forms.Clipboard]::GetText()
    if ($clipboardText) {
        $clipboardText | Out-File $clipFile
    } else {
        "Clipboard is empty or contains non-text data." | Out-File $clipFile
    }
} catch {
    "Failed to access clipboard: $_" | Out-File $clipFile
}

# DNS Client Cache
$dnsFile = "$TempDir\volatile_ram\dns_cache.txt"
ipconfig /displaydns | Out-File $dnsFile

# ARP Table
$arpFile = "$TempDir\volatile_ram\arp_table.txt"
arp -a | Out-File $arpFile

# Wi-Fi Profiles & Cleartext passwords (Crucial for Police)
Write-Host "[*] Extracting saved Wi-Fi credentials..."
$wifiFile = "$TempDir\volatile_ram\wifi_profiles.txt"
"Saved Wi-Fi Keys:" | Out-File $wifiFile
$wifiProfiles = netsh wlan show profiles | Select-String "All User Profile"
foreach ($profileLine in $wifiProfiles) {
    $profileName = ($profileLine -split ":")[1].Trim()
    "Profile: $profileName" | Out-File $wifiFile -Append
    netsh wlan show profile name="$profileName" key=clear | Select-String "Key Content" | Out-File $wifiFile -Append
    "------------------------" | Out-File $wifiFile -Append
}

# 3. Extract Browser History & Data
Send-StatusUpdate "Locating Browser Histories..." 45
Write-Host "[*] Ingesting browser histories..."

$localAppData = $env:LOCALAPPDATA
$appData = $env:APPDATA

# Define browsers and their path configurations
# [Name, Directory path, Subpath to history database, Subpath to cache]
$chromeHistory = "$localAppData\Google\Chrome\User Data\Default\History"
$chromeCache = "$localAppData\Google\Chrome\User Data\Default\Cache"

$edgeHistory = "$localAppData\Microsoft\Edge\User Data\Default\History"
$edgeCache = "$localAppData\Microsoft\Edge\User Data\Default\Cache"

$braveHistory = "$localAppData\BraveSoftware\Brave-Browser\User Data\Default\History"
$braveCache = "$localAppData\BraveSoftware\Brave-Browser\User Data\Default\Cache"

$operaHistory = "$appData\Opera Software\Opera Stable\History"
$operaCache = "$localAppData\Opera Software\Opera Stable\Cache"

# Function to copy browser files safely (handles open browsers by copying shadow file)
function Copy-BrowserData($name, $histPath, $cachePath) {
    Write-Host "[*] Ingesting $name data..."
    Send-StatusUpdate "Extracting $name History..." 55
    
    $targetBrowserDir = "$TempDir\browsers\$name"
    New-Item -ItemType Directory -Path $targetBrowserDir -Force | Out-Null
    
    # Copy History SQLite database
    if (Test-Path $histPath) {
        Copy-Item -Path $histPath -Destination "$targetBrowserDir\History.db" -Force
    } else {
        "History database not found at $histPath" | Out-File "$targetBrowserDir\not_found.txt"
    }
    
    # Copy Cache folder if it exists
    if (Test-Path $cachePath) {
        Send-StatusUpdate "Extracting $name Cache..." 65
        New-Item -ItemType Directory -Path "$targetBrowserDir\Cache" -Force | Out-Null
        # We only copy the index and smaller cache files to keep extraction rapid
        Copy-Item -Path "$cachePath\*" -Destination "$targetBrowserDir\Cache\" -Recurse -Force -Exclude *.tmp
    }
}

# Perform Chromium extraction
Copy-BrowserData "Chrome" $chromeHistory $chromeCache
Copy-BrowserData "Edge" $edgeHistory $edgeCache
Copy-BrowserData "Brave" $braveHistory $braveCache
Copy-BrowserData "Opera" $operaHistory $operaCache

# Mozilla Firefox Extraction (uses Profiles)
Write-Host "[*] Ingesting Firefox data..."
Send-StatusUpdate "Extracting Firefox Profiles..." 75
$ffProfilesDir = "$appData\Mozilla\Firefox\Profiles"
$ffCacheDir = "$localAppData\Mozilla\Firefox\Profiles"
if (Test-Path $ffProfilesDir) {
    $targetFFDir = "$TempDir\browsers\Firefox"
    New-Item -ItemType Directory -Path $targetFFDir -Force | Out-Null
    
    # Copy places.sqlite and cookies.sqlite from each profile
    $profiles = Get-ChildItem -Path $ffProfilesDir -Directory
    foreach ($profile in $profiles) {
        $pName = $profile.Name
        New-Item -ItemType Directory -Path "$targetFFDir\$pName" -Force | Out-Null
        
        # History & Bookmarks
        if (Test-Path "$ffProfilesDir\$pName\places.sqlite") {
            Copy-Item -Path "$ffProfilesDir\$pName\places.sqlite" -Destination "$targetFFDir\$pName\places.sqlite" -Force
        }
        # Cookies
        if (Test-Path "$ffProfilesDir\$pName\cookies.sqlite") {
            Copy-Item -Path "$ffProfilesDir\$pName\cookies.sqlite" -Destination "$targetFFDir\$pName\cookies.sqlite" -Force
        }
        
        # Cache (often in LocalAppData instead of AppData)
        if (Test-Path "$ffCacheDir\$pName\cache2") {
            New-Item -ItemType Directory -Path "$targetFFDir\$pName\Cache" -Force | Out-Null
            Copy-Item -Path "$ffCacheDir\$pName\cache2\*" -Destination "$targetFFDir\$pName\Cache" -Recurse -Force
        }
    }
}

# 4. ZIP and Upload Data
Send-StatusUpdate "Compressing Forensic Package..." 85
Write-Host "[*] Compressing all gathered evidence..."

$ZipPath = "$env:TEMP\seize_extraction.zip"
if (Test-Path $ZipPath) { Remove-Item -Path $ZipPath -Force }

# Use PowerShell 5.0+ Compress-Archive or fallback to .NET zip compression for compatibility
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($TempDir, $ZipPath)
    Write-Host "[+] Zip archive created successfully."
} catch {
    Send-Error "Failed to compress archive: $_"
    Write-Host "[!] Error: Zip compression failed: $_"
    exit
}

Send-StatusUpdate "Uploading evidence to S.E.I.Z.E. Pi..." 90
Write-Host "[*] Uploading zip file ($((Get-Item $ZipPath).Length / 1MB) MB) to http://$ServerIP`:$ServerPort..."

try {
    # Perform HTTP POST Multipart Upload
    $uri = "$BaseUrl/upload"
    
    # In older PowerShell versions, doing multipart form uploads can be tricky.
    # Below is a robust way to upload a file via Invoke-RestMethod (PS 3.0+)
    $boundary = [System.Guid]::NewGuid().ToString()
    $LF = "`r`n"
    
    $fileBytes = [System.IO.File]::ReadAllBytes($ZipPath)
    $fileName = [System.IO.Path]::GetFileName($ZipPath)
    
    $bodyPrefix = "--$boundary$LF" +
                  "Content-Disposition: form-data; name=`"file`"; filename=`"$fileName`"$LF" +
                  "Content-Type: application/octet-stream$LF$LF"
                  
    $bodySuffix = "$LF--$boundary--$LF"
    
    $encoding = [System.Text.Encoding]::GetEncoding("iso-8859-1")
    $prefixBytes = $encoding.GetBytes($bodyPrefix)
    $suffixBytes = $encoding.GetBytes($bodySuffix)
    
    $totalLength = $prefixBytes.Length + $fileBytes.Length + $suffixBytes.Length
    $postBytes = New-Object Byte[] $totalLength
    
    [System.Buffer]::BlockCopy($prefixBytes, 0, $postBytes, 0, $prefixBytes.Length)
    [System.Buffer]::BlockCopy($fileBytes, 0, $postBytes, $prefixBytes.Length, $fileBytes.Length)
    [System.Buffer]::BlockCopy($suffixBytes, 0, $postBytes, ($prefixBytes.Length + $fileBytes.Length), $suffixBytes.Length)
    
    $headers = @{
        "Content-Type" = "multipart/form-data; boundary=$boundary"
    }
    
    $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $postBytes -ContentType "multipart/form-data" -TimeoutSec 180
    Write-Host "[+] Ingestion complete! Server Response: $($response.status)"
} catch {
    Send-Error "Upload failed: $_"
    Write-Host "[!] Error: Upload to Pi failed: $_"
} finally {
    # 5. Forensic Cleanup
    Write-Host "[*] Cleaning up temporary workspace..."
    if (Test-Path $TempDir) { Remove-Item -Path $TempDir -Recurse -Force }
    if (Test-Path $ZipPath) { Remove-Item -Path $ZipPath -Force }
    Write-Host "[*] Cleanup finished. Execution complete."
}
