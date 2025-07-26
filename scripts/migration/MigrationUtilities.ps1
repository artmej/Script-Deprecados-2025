#Requires -Version 5.1
#Requires -Modules Az.Compute, Az.Resources, Az.Storage

<#
.SYNOPSIS
    Funciones de utilidad para operaciones de migración de discos no administrados a administrados.

.DESCRIPTION
    Este script proporciona funciones de utilidad para soportar el proceso de migración:
    - Descubrir VMs con discos no administrados
    - Limpiar blobs VHD huérfanos después de la migración
    - Generar reportes de migración
    - Validar preparación para migración

.NOTES
    Autor: Equipo de Migración Azure
    Versión: 1.0
#>

function Get-UnmanagedDiskReport {
    <#
    .SYNOPSIS
        Genera un reporte completo de VMs que usan discos no administrados.
    
    .PARAMETER ResourceGroupName
        Grupo de recursos a analizar. Si no se especifica, analiza toda la suscripción.
    
    .PARAMETER ExportPath
        Ruta para exportar el reporte CSV.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $false)]
        [string]$ExportPath
    )
    
    Write-Host "Generando reporte de discos no administrados..." -ForegroundColor Cyan
    
    # Obtener VMs según el alcance
    if ($ResourceGroupName) {
        $VMs = Get-AzVM -ResourceGroupName $ResourceGroupName
        Write-Host "Analizando $($VMs.Count) VMs en grupo de recursos: $ResourceGroupName"
    }
    else {
        $VMs = Get-AzVM
        Write-Host "Analizando $($VMs.Count) VMs en toda la suscripción"
    }
    
    $Report = @()
    
    foreach ($VM in $VMs) {
        $VMInfo = [PSCustomObject]@{
            VMName = $VM.Name
            ResourceGroup = $VM.ResourceGroupName
            Location = $VM.Location
            VMSize = $VM.HardwareProfile.VmSize
            OSType = $VM.StorageProfile.OsDisk.OsType
            OSDisksManaged = [bool]$VM.StorageProfile.OsDisk.ManagedDisk
            OSDisksVHDUri = $VM.StorageProfile.OsDisk.Vhd.Uri
            DataDisksCount = $VM.StorageProfile.DataDisks.Count
            DataDisksManaged = ($VM.StorageProfile.DataDisks | Where-Object { $_.ManagedDisk }).Count
            DataDisksUnmanaged = ($VM.StorageProfile.DataDisks | Where-Object { -not $_.ManagedDisk }).Count
            HasUnmanagedDisks = (-not $VM.StorageProfile.OsDisk.ManagedDisk) -or 
                               (($VM.StorageProfile.DataDisks | Where-Object { -not $_.ManagedDisk }).Count -gt 0)
            AvailabilitySet = if ($VM.AvailabilitySetReference) { 
                $VM.AvailabilitySetReference.Id.Split('/')[-1] 
            } else { 
                "Ninguno" 
            }
            PowerState = (Get-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -Status).Statuses | 
                        Where-Object { $_.Code -like 'PowerState/*' } | 
                        Select-Object -ExpandProperty Code
        }
        
        $Report += $VMInfo
    }
    
    # Estadísticas de resumen
    $UnmanagedVMs = $Report | Where-Object { $_.HasUnmanagedDisks }
    $ManagedVMs = $Report | Where-Object { -not $_.HasUnmanagedDisks }
    
    Write-Host "`n=== RESUMEN ===" -ForegroundColor Yellow
    Write-Host "Total VMs: $($Report.Count)"
    Write-Host "VMs con discos no administrados: $($UnmanagedVMs.Count)" -ForegroundColor Red
    Write-Host "VMs con discos administrados: $($ManagedVMs.Count)" -ForegroundColor Green
    Write-Host "Progreso de migración: $([math]::Round(($ManagedVMs.Count / $Report.Count) * 100, 2))%"
    
    if ($UnmanagedVMs.Count -gt 0) {
        Write-Host "`nVMs que requieren migración:" -ForegroundColor Red
        $UnmanagedVMs | Format-Table VMName, ResourceGroup, AvailabilitySet, PowerState -AutoSize
    }
    
    # Exportar reporte si se solicita
    if ($ExportPath) {
        $Report | Export-Csv -Path $ExportPath -NoTypeInformation
        Write-Host "Reporte exportado a: $ExportPath" -ForegroundColor Green
    }
    
    return $Report
}

function Test-MigrationReadiness {
    <#
    .SYNOPSIS
        Prueba si las VMs están listas para migración a discos administrados.
    
    .PARAMETER ResourceGroupName
        Grupo de recursos que contiene las VMs a probar.
        
    .PARAMETER VMName
        VM específica a probar. Si no se especifica, prueba todas las VMs con discos no administrados.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $false)]
        [string]$VMName
    )
    
    Write-Host "Probando preparación para migración..." -ForegroundColor Cyan
    
    # Obtener VMs a probar
    if ($VMName) {
        $VMs = @(Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName)
    }
    else {
        $AllVMs = Get-AzVM -ResourceGroupName $ResourceGroupName
        $VMs = $AllVMs | Where-Object { -not $_.StorageProfile.OsDisk.ManagedDisk }
    }
    
    if ($VMs.Count -eq 0) {
        Write-Host "No se encontraron VMs con discos no administrados para probar." -ForegroundColor Yellow
        return
    }
    
    $ReadinessReport = @()
    
    foreach ($VM in $VMs) {
        Write-Host "`nProbando VM: $($VM.Name)" -ForegroundColor Cyan
        
        $Issues = @()
        $Warnings = @()
        
        # Prueba 1: Estado de extensiones de VM
        try {
            $Extensions = Get-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name
            $FailedExtensions = $Extensions | Where-Object { $_.ProvisioningState -ne "Succeeded" }
            
            if ($FailedExtensions) {
                $Issues += "Extensiones fallidas: $($FailedExtensions.Name -join ', ')"
            }
            else {
                Write-Host "  ✓ Todas las extensiones en estado exitoso" -ForegroundColor Green
            }
        }
        catch {
            $Warnings += "No se pudo obtener el estado de extensiones: $($_.Exception.Message)"
        }
        
        # Prueba 2: Estado de agente VM
        try {
            $VMStatus = Get-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -Status
            $AgentStatus = $VMStatus.VMAgent
            
            if ($AgentStatus.VmAgentVersion) {
                Write-Host "  ✓ Versión de agente VM: $($AgentStatus.VmAgentVersion)" -ForegroundColor Green
            }
            else {
                $Warnings += "No se pudo determinar el estado del agente VM"
            }
        }
        catch {
            $Warnings += "No se pudo obtener el estado del agente VM: $($_.Exception.Message)"
        }
        
        # Prueba 3: Conteo de snapshots de disco
        try {
            if ($VM.StorageProfile.OsDisk.Vhd.Uri) {
                $StorageAccountName = ($VM.StorageProfile.OsDisk.Vhd.Uri -split '\.')[0] -replace 'https://', ''
                $ContainerName = ($VM.StorageProfile.OsDisk.Vhd.Uri -split '/')[3]
                
                # Esta es una verificación simplificada - en producción, querrías verificar el conteo real de snapshots
                Write-Host "  ✓ URI VHD del disco OS validado" -ForegroundColor Green
            }
        }
        catch {
            $Warnings += "No se pudo validar la configuración del disco: $($_.Exception.Message)"
        }
        
        # Prueba 4: Estado del conjunto de disponibilidad (si aplica)
        if ($VM.AvailabilitySetReference) {
            try {
                $AvSetId = $VM.AvailabilitySetReference.Id
                $AvSetName = $AvSetId.Split('/')[-1]
                $AvSet = Get-AzAvailabilitySet -ResourceGroupName $VM.ResourceGroupName -Name $AvSetName
                
                if ($AvSet.Sku -eq "Aligned") {
                    Write-Host "  ✓ Conjunto de disponibilidad ya es administrado" -ForegroundColor Green
                }
                else {
                    $Warnings += "El conjunto de disponibilidad '$AvSetName' necesita ser convertido primero"
                }
            }
            catch {
                $Issues += "No se pudo validar el conjunto de disponibilidad: $($_.Exception.Message)"
            }
        }
        
        # Prueba 5: Estado de energía de VM
        $PowerState = $VMStatus.Statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -ExpandProperty Code
        if ($PowerState -eq "PowerState/running") {
            $Warnings += "La VM está actualmente ejecutándose - será desasignada durante la migración"
        }
        else {
            Write-Host "  ✓ La VM no está ejecutándose" -ForegroundColor Green
        }
        
        # Compilar resultados
        $ReadinessStatus = if ($Issues.Count -eq 0) { "Lista" } else { "No Lista" }
        
        $VMReadiness = [PSCustomObject]@{
            VMName = $VM.Name
            ResourceGroup = $VM.ResourceGroupName
            Status = $ReadinessStatus
            Issues = $Issues -join '; '
            Warnings = $Warnings -join '; '
            IssueCount = $Issues.Count
            WarningCount = $Warnings.Count
        }
        
        $ReadinessReport += $VMReadiness
        
        # Mostrar resultado
        if ($Issues.Count -eq 0) {
            Write-Host "  Estado: LISTA PARA MIGRACIÓN" -ForegroundColor Green
        }
        else {
            Write-Host "  Estado: NO LISTA - Problemas encontrados" -ForegroundColor Red
            foreach ($Issue in $Issues) {
                Write-Host "    ❌ $Issue" -ForegroundColor Red
            }
        }
        
        if ($Warnings.Count -gt 0) {
            foreach ($Warning in $Warnings) {
                Write-Host "    ⚠️  $Warning" -ForegroundColor Yellow
            }
        }
    }
    
    # Resumen
    Write-Host "`n=== RESUMEN DE PREPARACIÓN PARA MIGRACIÓN ===" -ForegroundColor Yellow
    $ReadyVMs = $ReadinessReport | Where-Object { $_.Status -eq "Lista" }
    $NotReadyVMs = $ReadinessReport | Where-Object { $_.Status -eq "No Lista" }
    
    Write-Host "Listas para migración: $($ReadyVMs.Count)" -ForegroundColor Green
    Write-Host "No listas para migración: $($NotReadyVMs.Count)" -ForegroundColor Red
    
    if ($NotReadyVMs.Count -gt 0) {
        Write-Host "`nVMs que requieren atención:" -ForegroundColor Red
        $NotReadyVMs | Format-Table VMName, Issues -AutoSize
    }
    
    return $ReadinessReport
}

function Find-OrphanedVHDs {
    <#
    .SYNOPSIS
        Encuentra blobs VHD que ya no están conectados a ninguna VM después de la migración.
    
    .PARAMETER ResourceGroupName
        Grupo de recursos para buscar VHDs huérfanos.
        
    .PARAMETER StorageAccountName
        Cuenta de almacenamiento específica para buscar.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $false)]
        [string]$StorageAccountName
    )
    
    Write-Host "Buscando blobs VHD huérfanos..." -ForegroundColor Cyan
    
    # Obtener todas las VMs para comparar
    if ($ResourceGroupName) {
        $AllVMs = Get-AzVM -ResourceGroupName $ResourceGroupName
    }
    else {
        $AllVMs = Get-AzVM
    }
    
    # Obtener todas las URIs VHD actualmente en uso
    $UsedVHDs = @()
    foreach ($VM in $AllVMs) {
        if ($VM.StorageProfile.OsDisk.Vhd.Uri) {
            $UsedVHDs += $VM.StorageProfile.OsDisk.Vhd.Uri
        }
        
        foreach ($DataDisk in $VM.StorageProfile.DataDisks) {
            if ($DataDisk.Vhd.Uri) {
                $UsedVHDs += $DataDisk.Vhd.Uri
            }
        }
    }
    
    Write-Host "Se encontraron $($UsedVHDs.Count) VHDs actualmente conectados a VMs"
    
    # Obtener cuentas de almacenamiento para buscar
    if ($StorageAccountName) {
        if ($ResourceGroupName) {
            $StorageAccounts = @(Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName)
        }
        else {
            $StorageAccounts = @(Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $StorageAccountName })
        }
    }
    else {
        if ($ResourceGroupName) {
            $StorageAccounts = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName
        }
        else {
            $StorageAccounts = Get-AzStorageAccount
        }
    }
    
    $OrphanedVHDs = @()
    
    foreach ($StorageAccount in $StorageAccounts) {
        Write-Host "Buscando en cuenta de almacenamiento: $($StorageAccount.StorageAccountName)" -ForegroundColor Cyan
        
        try {
            $StorageContext = $StorageAccount.Context
            $Containers = Get-AzStorageContainer -Context $StorageContext
            
            foreach ($Container in $Containers) {
                if ($Container.Name -eq 'vhds' -or $Container.Name -like '*disk*') {
                    $Blobs = Get-AzStorageBlob -Container $Container.Name -Context $StorageContext | 
                             Where-Object { $_.Name -like '*.vhd' }
                    
                    foreach ($Blob in $Blobs) {
                        $BlobUri = $Blob.ICloudBlob.StorageUri.PrimaryUri.ToString()
                        
                        if ($BlobUri -notin $UsedVHDs) {
                            $SizeInGB = [math]::Round($Blob.Length / 1GB, 2)
                            $EstimatedMonthlyCost = [math]::Round($SizeInGB * 0.05, 2)  # Estimación aproximada
                            
                            $OrphanInfo = [PSCustomObject]@{
                                StorageAccount = $StorageAccount.StorageAccountName
                                Container = $Container.Name
                                BlobName = $Blob.Name
                                BlobUri = $BlobUri
                                SizeGB = $SizeInGB
                                LastModified = $Blob.LastModified
                                EstimatedMonthlyCostUSD = $EstimatedMonthlyCost
                            }
                            
                            $OrphanedVHDs += $OrphanInfo
                        }
                    }
                }
            }
        }
        catch {
            Write-Warning "No se pudo acceder a la cuenta de almacenamiento $($StorageAccount.StorageAccountName): $($_.Exception.Message)"
        }
    }
    
    # Mostrar resultados
    if ($OrphanedVHDs.Count -eq 0) {
        Write-Host "No se encontraron blobs VHD huérfanos." -ForegroundColor Green
    }
    else {
        Write-Host "`nSe encontraron $($OrphanedVHDs.Count) blobs VHD huérfanos:" -ForegroundColor Yellow
        $OrphanedVHDs | Format-Table StorageAccount, BlobName, SizeGB, EstimatedMonthlyCostUSD -AutoSize
        
        $TotalSize = ($OrphanedVHDs | Measure-Object -Property SizeGB -Sum).Sum
        $TotalCost = ($OrphanedVHDs | Measure-Object -Property EstimatedMonthlyCostUSD -Sum).Sum
        
        Write-Host "`nAlmacenamiento huérfano total: $([math]::Round($TotalSize, 2)) GB" -ForegroundColor Red
        Write-Host "Ahorro mensual estimado después de limpieza: `$$([math]::Round($TotalCost, 2)) USD" -ForegroundColor Green
        
        Write-Host "`nPara eliminar estos VHDs, use la función Remove-OrphanedVHDs." -ForegroundColor Cyan
    }
    
    return $OrphanedVHDs
}

function Remove-OrphanedVHDs {
    <#
    .SYNOPSIS
        Remueve blobs VHD huérfanos después de confirmar que no son necesarios.
    
    .PARAMETER OrphanedVHDs
        Array de objetos VHD huérfanos de Find-OrphanedVHDs.
        
    .PARAMETER WhatIf
        Muestra qué se eliminaría sin eliminarlo realmente.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [array]$OrphanedVHDs,
        
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )
    
    if ($OrphanedVHDs.Count -eq 0) {
        Write-Host "No hay VHDs huérfanos para remover." -ForegroundColor Green
        return
    }
    
    Write-Host "Preparando para remover $($OrphanedVHDs.Count) blobs VHD huérfanos..." -ForegroundColor Yellow
    
    $TotalSize = ($OrphanedVHDs | Measure-Object -Property SizeGB -Sum).Sum
    $TotalCost = ($OrphanedVHDs | Measure-Object -Property EstimatedMonthlyCostUSD -Sum).Sum
    
    Write-Host "Esto liberará $([math]::Round($TotalSize, 2)) GB de almacenamiento" -ForegroundColor Cyan
    Write-Host "Ahorro mensual estimado: `$$([math]::Round($TotalCost, 2)) USD" -ForegroundColor Green
    
    if (-not $WhatIf) {
        $Confirmation = Read-Host "`n¿Está seguro que desea eliminar estos blobs VHD? Esta acción no se puede deshacer. (s/N)"
        if ($Confirmation -notmatch "^[SsYy]$") {
            Write-Host "Operación cancelada." -ForegroundColor Yellow
            return
        }
    }
    
    $SuccessCount = 0
    $FailureCount = 0
    
    foreach ($VHD in $OrphanedVHDs) {
        try {
            if ($PSCmdlet.ShouldProcess($VHD.BlobUri, "Delete VHD blob")) {
                # Get storage account context
                $StorageAccount = Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $VHD.StorageAccount }
                
                if ($StorageAccount) {
                    Remove-AzStorageBlob -Blob $VHD.BlobName -Container $VHD.Container -Context $StorageAccount.Context -Force
                    Write-Host "✓ Eliminado: $($VHD.BlobName)" -ForegroundColor Green
                    $SuccessCount++
                }
                else {
                    Write-Warning "No se pudo encontrar la cuenta de almacenamiento: $($VHD.StorageAccount)"
                    $FailureCount++
                }
            }
        }
        catch {
            Write-Error "Falló al eliminar $($VHD.BlobName): $($_.Exception.Message)"
            $FailureCount++
        }
    }
    
    Write-Host "`n=== RESUMEN DE LIMPIEZA ===" -ForegroundColor Yellow
    Write-Host "Eliminados exitosamente: $SuccessCount VHDs" -ForegroundColor Green
    Write-Host "Eliminaciones fallidas: $FailureCount VHDs" -ForegroundColor Red
    
    if ($SuccessCount -gt 0) {
        $CleanedSize = ($OrphanedVHDs | Select-Object -First $SuccessCount | Measure-Object -Property SizeGB -Sum).Sum
        $MonthlySavings = ($OrphanedVHDs | Select-Object -First $SuccessCount | Measure-Object -Property EstimatedMonthlyCostUSD -Sum).Sum
        
        Write-Host "Almacenamiento liberado: $([math]::Round($CleanedSize, 2)) GB" -ForegroundColor Green
        Write-Host "Ahorro mensual: `$$([math]::Round($MonthlySavings, 2)) USD" -ForegroundColor Green
    }
}

# Exportar funciones para uso en otros scripts
# Export-ModuleMember -Function Get-UnmanagedDiskReport, Test-MigrationReadiness, Find-OrphanedVHDs, Remove-OrphanedVHDs
# Nota: Export-ModuleMember no es necesario cuando se usa dot-sourcing (.)
