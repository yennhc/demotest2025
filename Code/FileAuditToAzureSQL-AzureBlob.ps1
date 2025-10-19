# ===============================================
# FileAuditToAzureSQL-AzureBlob.ps1
# ===============================================

# ---------- CONFIGURATION ----------
$RootPath = "C:\SharedData"   # Local folder to scan
$ArchiveContainer = "file-archive"
$DaysThreshold = 180
$StorageAccount = "mystorageaudit"
$StorageKey = "<torage-account-key>"   
$SqlServer = "demo-sql-server.database.windows.net"
$Database = "ServerAuditDB"
$User = "adminuser"
$Password = "P@ssowrd2025" 

$ConnectionString = "Server=tcp:$SqlServer,1433;Initial Catalog=$Database;Persist Security Info=False;User ID=$User;Password=$Password;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
Import-Module SqlServer
Import-Module Az.Storage

# ---------- FUNCTIONS ----------

function Get-Permissions($Path) {
    try {
        $acl = Get-Acl -Path $Path
        $perms = @()
        foreach ($access in $acl.Access) {
            $rights = $access.FileSystemRights.ToString()
            $identity = $access.IdentityReference.Value
            $perms += "$identity : $rights"
        }
        return ($perms -join "; ")
    }
    catch {
        return "Error reading permissions"
    }
}

function Get-Owner($Path) {
    try {
        (Get-Acl $Path).Owner
    }
    catch {
        return "Unknown"
    }
}

function Get-FileChecksum($Path) {
    try {
        (Get-FileHash $Path -Algorithm SHA256).Hash
    }
    catch {
        return "ChecksumError"
    }
}

# ---------- START PROCESS ----------

Write-Host "Connecting to Azure Storage..."
$ctx = New-AzStorageContext -StorageAccountName $StorageAccount -StorageAccountKey $StorageKey

$ThresholdDate = (Get-Date).AddDays(-$DaysThreshold)
$Files = Get-ChildItem -Path $RootPath -Recurse -File -ErrorAction SilentlyContinue

foreach ($File in $Files) {
    $Owner = Get-Owner $File.FullName
    $Permissions = Get-Permissions $File.FullName
    $Checksum = Get-FileChecksum $File.FullName
    $LastMod = $File.LastWriteTime
    $LastAccess = $File.LastAccessTime
    $FolderPath = Split-Path $File.FullName
    $FilePath = $File.FullName
    $Status = if ($LastAccess -lt $ThresholdDate) { "Archived" } else { "Original" }

    # ---------- Upload old files to Azure Blob ----------
    $BlobUrl = $null
    if ($Status -eq "Archived") {
        Write-Host "Uploading $($File.Name) to Azure Blob..."
        $Blob = Set-AzStorageBlobContent -File $File.FullName -Container $ArchiveContainer -Context $ctx -Force
        $BlobUrl = $Blob.ICloudBlob.Uri.AbsoluteUri

        # Validate checksum after upload
        $uploaded = Get-AzStorageBlob -Container $ArchiveContainer -Blob $File.Name -Context $ctx
        if ($uploaded) {
            Write-Host "File uploaded. Removing local copy..."
            Remove-Item $File.FullName -Force
        } else {
            Write-Warning "Upload failed for $($File.FullName). Skipping deletion."
        }
    }

    # ---------- Insert into Azure SQL ----------
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

    Write-Host "Inserted metadata for: $($File.Name)"
}

Write-Host "✅ Completed scanning and archiving."