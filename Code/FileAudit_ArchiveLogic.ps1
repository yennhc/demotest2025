# =======================================================
# FileAudit_ArchiveLogic.ps1
# =======================================================

# ---------- CONFIGURATION ----------
$RootPath = "C:\SharedData"   # Local folder to scan
$ArchiveContainer = "file-archive"
$DaysThreshold = 180
$StorageAccount = "mystorageaudit"
$StorageKey = "<storage-key>"
$SqlServer = "demo-sql-server.database.windows.net"
$Database = "ServerAuditDB"
$User = "adminuser"
$Password = "P@ssowrd2025"   # Secure later

$ConnectionString = "Server=tcp:$SqlServer,1433;Initial Catalog=$Database;Persist Security Info=False;User ID=$User;Password=$Password;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

# ---------- MODULES ----------
Import-Module Az.Storage
Import-Module SqlServer

# ---------- FUNCTIONS ----------
function Get-Permissions($Path) {
    try {
        $acl = Get-Acl -Path $Path
        $perms = $acl.Access | ForEach-Object { "$($_.IdentityReference):$($_.FileSystemRights)" }
        return ($perms -join "; ")
    } catch { return "Error reading permissions" }
}

function Get-Owner($Path) {
    try { (Get-Acl $Path).Owner } catch { return "Unknown" }
}

function Get-Checksum($Path) {
    try { (Get-FileHash $Path -Algorithm SHA256).Hash } catch { return "ChecksumError" }
}

function Compare-Checksums($localHash, $blobHash) {
    return ($localHash -eq $blobHash)
}

# ---------- CONNECT TO AZURE ----------
$ctx = New-AzStorageContext -StorageAccountName $StorageAccount -StorageAccountKey $StorageKey
$ThresholdDate = (Get-Date).AddDays(-$DaysThreshold)

# ---------- START SCANNING ----------
$Files = Get-ChildItem -Path $RootPath -Recurse -File -ErrorAction SilentlyContinue

foreach ($File in $Files) {
    $Owner = Get-Owner $File.FullName
    $Permissions = Get-Permissions $File.FullName
    $ChecksumLocal = Get-Checksum $File.FullName
    $LastMod = $File.LastWriteTime
    $LastAccess = $File.LastAccessTime
    $FolderPath = Split-Path $File.FullName
    $FilePath = $File.FullName
    $Status = if ($LastAccess -lt $ThresholdDate) { "Archived" } else { "Original" }

    $BlobUrl = $null

    if ($Status -eq "Archived") {
        Write-Host "Archiving file: $($File.FullName)..."

        # Step 1: Upload file to blob
        $Blob = Set-AzStorageBlobContent -File $File.FullName -Container $ArchiveContainer -Context $ctx -Force
        $BlobUrl = $Blob.ICloudBlob.Uri.AbsoluteUri

        # Step 2: Download blob temporarily for checksum validation
        $TempPath = "$env:TEMP\$($File.Name)"
        Get-AzStorageBlobContent -Container $ArchiveContainer -Blob $File.Name -Destination $TempPath -Context $ctx -Force
        $ChecksumBlob = Get-Checksum $TempPath

        if (Compare-Checksums $ChecksumLocal $ChecksumBlob) {
            Write-Host "Checksum validated ✅ - Deleting local file..."
            Remove-Item $File.FullName -Force
            Remove-Item $TempPath -Force
        }
        else {
            Write-Warning "Checksum mismatch - File will NOT be deleted!"
            Remove-Item $TempPath -Force
            $Status = "ChecksumError"
        }
    }

    # ---------- UPDATE DATABASE ----------
    $Query = @"
    INSERT INTO FileAudit (FileName, FilePath, FolderPath, Owner, LastModified, LastAccess, Permissions, Status)
    VALUES (
        '$(($File.Name).Replace("'", "''"))',
        '$(($FilePath).Replace("'", "''"))',
        '$(($FolderPath).Replace("'", "''"))',
        '$(($Owner).Replace("'", "''"))',
        '$LastMod',
        '$LastAccess',
        '$(($Permissions).Replace("'", "''"))',
        '$Status'
    );
"@

    Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $Query -ErrorAction Stop

    # Step 3: If file was archived, update database with blob URL
    if ($Status -eq "Archived") {
        $UpdateQuery = "UPDATE FileAudit SET FilePath='$BlobUrl' WHERE FileName='$(($File.Name).Replace("'", "''"))';"
        Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $UpdateQuery -ErrorAction Stop
    }

    Write-Host "Processed: $($File.Name) | Status: $Status"
}

Write-Host "File scanning and archiving completed successfully."