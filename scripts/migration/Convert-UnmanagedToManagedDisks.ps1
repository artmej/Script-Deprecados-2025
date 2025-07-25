#Requires -Version 5.1
#Requires -Modules Az.Compute, Az.Resources

<#
.SYNOPSIS
    Migra máquinas virtuales de Azure de discos no administrados a discos administrados.

.DESCRIPTION
    Este script automatiza la migración de VMs de Azure de discos no administrados a discos administrados.
    Soporta tanto VMs individuales como VMs en conjuntos de disponibilidad.
    
    El proceso de migración:
    1. Valida prerequisitos y estado de la VM
    2. Maneja la migración del conjunto de disponibilidad si es necesario
    3. Desasigna las VMs
    4. Convierte los discos a discos administrados
    5. Proporciona validación post-migración

.PARAMETER ResourceGroupName
    El nombre del grupo de recursos que contiene la(s) VM(s).

.PARAMETER VMName
    El nombre de la VM específica a migrar. Si no se especifica, se procesarán todas las VMs del grupo de recursos.

.PARAMETER AvailabilitySetName
    El nombre del conjunto de disponibilidad a migrar (si aplica).

.PARAMETER WhatIf
    Muestra qué pasaría sin realizar realmente la migración.

.PARAMETER Force
    Omite las confirmaciones de usuario.

.PARAMETER LogPath
    Ruta para almacenar los logs de migración. Por defecto es el directorio actual.

.EXAMPLE
    .\Convert-UnmanagedToManagedDisks.ps1 -ResourceGroupName "myRG" -VMName "myVM"
    
.EXAMPLE
    .\Convert-UnmanagedToManagedDisks.ps1 -ResourceGroupName "myRG" -AvailabilitySetName "myAvSet"

.NOTES
    Autor: Equipo de Migración Azure
    Versión: 1.0
    
    Prerequisitos:
    - Módulo de Azure PowerShell (Az.Compute, Az.Resources)
    - Permisos apropiados de Azure
    - VM debe estar en estado saludable
    - Todas las extensiones de VM en estado 'Provisioning succeeded'
    
    Importante:
    - La migración no es reversible
    - La VM será desasignada y recibirá una nueva dirección IP
    - Los VHDs originales permanecerán y generarán costos hasta ser eliminados manualmente
    - Programar durante ventana de mantenimiento
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$VMName,

    [Parameter(Mandatory = $false)]
    [string]$AvailabilitySetName,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "."
)

# Inicializar logging
$LogFile = Join-Path $LogPath "UnmanagedToManagedMigration_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "[$Timestamp] [$Level] $Message"
    Write-Host $LogMessage
    Add-Content -Path $LogFile -Value $LogMessage
}

function Test-Prerequisites {
    Write-Log "Verificando prerequisitos..."
    
    # Verificar si los módulos requeridos están disponibles
    $RequiredModules = @('Az.Compute', 'Az.Resources')
    foreach ($Module in $RequiredModules) {
        if (-not (Get-Module -ListAvailable -Name $Module)) {
            Write-Log "El módulo requerido $Module no está instalado" -Level "ERROR"
            throw "Módulo requerido faltante: $Module. Por favor instalar usando: Install-Module $Module"
        }
    }
    
    # Verificar contexto de Azure
    try {
        $Context = Get-AzContext
        if (-not $Context) {
            Write-Log "No se encontró contexto de Azure. Por favor ejecutar Connect-AzAccount" -Level "ERROR"
            throw "No conectado a Azure. Por favor ejecutar Connect-AzAccount"
        }
        Write-Log "Conectado a la suscripción de Azure: $($Context.Subscription.Name)"
    }
    catch {
        Write-Log "Error al obtener contexto de Azure: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
    
    # Validar grupo de recursos
    try {
        $ResourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop
        Write-Log "Grupo de recursos '$ResourceGroupName' encontrado en ubicación: $($ResourceGroup.Location)"
    }
    catch {
        Write-Log "Grupo de recursos '$ResourceGroupName' no encontrado: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Test-VMState {
    param([object]$VM)
    
    Write-Log "Validando estado de VM para: $($VM.Name)"
    
    # Verificar si la VM usa discos no administrados
    if ($VM.StorageProfile.OsDisk.ManagedDisk) {
        Write-Log "La VM '$($VM.Name)' ya usa discos administrados para el disco del SO" -Level "WARNING"
        return $false
    }
    
    # Verificar extensiones de VM
    $Extensions = Get-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name
    foreach ($Extension in $Extensions) {
        if ($Extension.ProvisioningState -ne "Succeeded") {
            Write-Log "La extensión de VM '$($Extension.Name)' no está en estado 'Succeeded': $($Extension.ProvisioningState)" -Level "ERROR"
            throw "La VM '$($VM.Name)' tiene extensiones que no están en estado 'Succeeded'. La migración no puede continuar."
        }
    }
    
    Write-Log "Validación de estado de VM '$($VM.Name)' completada exitosamente"
    return $true
}

function Convert-AvailabilitySet {
    param([string]$AvSetName)
    
    Write-Log "Convirtiendo conjunto de disponibilidad '$AvSetName' a administrado"
    
    try {
        $AvSet = Get-AzAvailabilitySet -ResourceGroupName $ResourceGroupName -Name $AvSetName -ErrorAction Stop
        
        if ($AvSet.Sku -eq "Aligned") {
            Write-Log "El conjunto de disponibilidad '$AvSetName' ya es administrado"
            return $AvSet
        }
        
        if ($PSCmdlet.ShouldProcess($AvSetName, "Convertir conjunto de disponibilidad a administrado")) {
            # Manejar ajuste de cantidad de dominios de fallo si es necesario
            $CurrentRegion = $AvSet.Location
            Write-Log "Verificando requisitos de dominio de fallo para la región: $CurrentRegion"
            
            # La mayoría de regiones soportan 2 dominios de fallo para conjuntos de disponibilidad administrados
            if ($AvSet.PlatformFaultDomainCount -gt 2) {
                Write-Log "Ajustando cantidad de dominios de fallo de $($AvSet.PlatformFaultDomainCount) a 2"
                $AvSet.PlatformFaultDomainCount = 2
            }
            
            $AvSet = Update-AzAvailabilitySet -AvailabilitySet $AvSet -Sku Aligned
            Write-Log "Conjunto de disponibilidad '$AvSetName' convertido exitosamente a administrado"
        }
        
        return $AvSet
    }
    catch {
        Write-Log "Error al convertir conjunto de disponibilidad '$AvSetName': $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Convert-VMToManagedDisks {
    param([object]$VM)
    
    $VMName = $VM.Name
    Write-Log "Iniciando migración para VM: $VMName"
    
    try {
        # Validar estado de VM
        if (-not (Test-VMState -VM $VM)) {
            Write-Log "Omitiendo VM '$VMName' - ya usa discos administrados o la validación falló" -Level "WARNING"
            return
        }
        
        if ($PSCmdlet.ShouldProcess($VMName, "Migrar VM a discos administrados")) {
            # Paso 1: Desasignar VM
            Write-Log "Desasignando VM: $VMName"
            Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force
            Write-Log "VM '$VMName' desasignada exitosamente"
            
            # Paso 2: Convertir a discos administrados
            Write-Log "Convirtiendo VM '$VMName' a discos administrados"
            ConvertTo-AzVMManagedDisk -ResourceGroupName $ResourceGroupName -VMName $VMName
            Write-Log "VM '$VMName' convertida a discos administrados exitosamente"
            
            # Paso 3: Validar conversión
            $UpdatedVM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
            if ($UpdatedVM.StorageProfile.OsDisk.ManagedDisk) {
                Write-Log "Migración verificada - VM '$VMName' ahora usa discos administrados" -Level "SUCCESS"
                
                # Registrar información de discos
                Write-Log "Disco del SO: $($UpdatedVM.StorageProfile.OsDisk.ManagedDisk.Id)"
                foreach ($DataDisk in $UpdatedVM.StorageProfile.DataDisks) {
                    if ($DataDisk.ManagedDisk) {
                        Write-Log "Disco de Datos: $($DataDisk.ManagedDisk.Id)"
                    }
                }
            }
            else {
                Write-Log "Verificación de migración falló para VM '$VMName'" -Level "ERROR"
            }
        }
    }
    catch {
        Write-Log "Error al migrar VM '$VMName': $($_.Exception.Message)" -Level "ERROR"
        
        # Lógica de reintento para fallas transitorias comunes
        if ($_.Exception.Message -match "SnapshotCountExceeded") {
            Write-Log "Reintentando migración debido a error SnapshotCountExceeded..." -Level "WARNING"
            Start-Sleep -Seconds 30
            try {
                ConvertTo-AzVMManagedDisk -ResourceGroupName $ResourceGroupName -VMName $VMName
                Write-Log "Reintento exitoso para VM '$VMName'" -Level "SUCCESS"
            }
            catch {
                Write-Log "Reintento falló para VM '$VMName': $($_.Exception.Message)" -Level "ERROR"
                throw
            }
        }
        else {
            throw
        }
    }
}

function Get-UnmanagedVMs {
    Write-Log "Descubriendo VMs con discos no administrados..."
    
    if ($VMName) {
        # VM específica indicada
        try {
            $VM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop
            if (-not $VM.StorageProfile.OsDisk.ManagedDisk) {
                return @($VM)
            }
            else {
                Write-Log "La VM '$VMName' ya usa discos administrados" -Level "WARNING"
                return @()
            }
        }
        catch {
            Write-Log "VM '$VMName' no encontrada: $($_.Exception.Message)" -Level "ERROR"
            throw
        }
    }
    else {
        # Todas las VMs en el grupo de recursos
        $AllVMs = Get-AzVM -ResourceGroupName $ResourceGroupName
        $UnmanagedVMs = $AllVMs | Where-Object { -not $_.StorageProfile.OsDisk.ManagedDisk }
        
        Write-Log "Se encontraron $($UnmanagedVMs.Count) VMs con discos no administrados de $($AllVMs.Count) VMs totales"
        return $UnmanagedVMs
    }
}

function Show-MigrationSummary {
    param([array]$VMs)
    
    Write-Log "=== RESUMEN DE MIGRACIÓN ==="
    Write-Log "Grupo de Recursos: $ResourceGroupName"
    Write-Log "VMs a migrar: $($VMs.Count)"
    
    foreach ($VM in $VMs) {
        Write-Log "  - $($VM.Name) (Ubicación: $($VM.Location))"
        if ($VM.AvailabilitySetReference) {
            $AvSetId = $VM.AvailabilitySetReference.Id
            $AvSetNameFromId = $AvSetId.Split('/')[-1]
            Write-Log "    Conjunto de Disponibilidad: $AvSetNameFromId"
        }
    }
    
    Write-Log "=========================="
}

# Ejecución principal
try {
    Write-Log "Iniciando migración de VMs de Azure de discos no administrados a administrados"
    Write-Log "Archivo de log: $LogFile"
    
    # Paso 1: Verificación de prerequisitos
    Test-Prerequisites
    
    # Paso 2: Descubrir VMs a migrar
    $VMsToMigrate = Get-UnmanagedVMs
    
    if ($VMsToMigrate.Count -eq 0) {
        Write-Log "No se encontraron VMs con discos no administrados. Saliendo." -Level "WARNING"
        return
    }
    
    # Paso 3: Mostrar resumen de migración
    Show-MigrationSummary -VMs $VMsToMigrate
    
    # Paso 4: Confirmación
    if (-not $Force -and -not $WhatIf) {
        $Confirmation = Read-Host "¿Desea proceder con la migración? (s/N)"
        if ($Confirmation -notmatch "^[SsYy]$") {
            Write-Log "Migración cancelada por el usuario"
            return
        }
    }
    
    # Paso 5: Manejar migración de conjunto de disponibilidad si es necesario
    if ($AvailabilitySetName) {
        Convert-AvailabilitySet -AvSetName $AvailabilitySetName
    }
    else {
        # Verificar si alguna VM está en conjuntos de disponibilidad
        $AvailabilitySets = @()
        foreach ($VM in $VMsToMigrate) {
            if ($VM.AvailabilitySetReference) {
                $AvSetId = $VM.AvailabilitySetReference.Id
                $AvSetName = $AvSetId.Split('/')[-1]
                if ($AvSetName -notin $AvailabilitySets) {
                    $AvailabilitySets += $AvSetName
                }
            }
        }
        
        foreach ($AvSetName in $AvailabilitySets) {
            Convert-AvailabilitySet -AvSetName $AvSetName
        }
    }
    
    # Paso 6: Migrar VMs
    $SuccessCount = 0
    $FailureCount = 0
    
    foreach ($VM in $VMsToMigrate) {
        try {
            Convert-VMToManagedDisks -VM $VM
            $SuccessCount++
        }
        catch {
            Write-Log "Error al migrar VM '$($VM.Name)': $($_.Exception.Message)" -Level "ERROR"
            $FailureCount++
        }
    }
    
    # Paso 7: Resumen final
    Write-Log "=== MIGRACIÓN COMPLETADA ==="
    Write-Log "Migradas exitosamente: $SuccessCount VMs"
    Write-Log "Migraciones fallidas: $FailureCount VMs"
    Write-Log "Archivo de log: $LogFile"
    
    if ($FailureCount -eq 0) {
        Write-Log "¡Todas las VMs migradas exitosamente!" -Level "SUCCESS"
        Write-Log ""
        Write-Log "TAREAS IMPORTANTES POST-MIGRACIÓN:"
        Write-Log "1. Verificar que todas las VMs funcionen correctamente"
        Write-Log "2. Actualizar scripts/automatización que referencien URIs de discos antiguos"
        Write-Log "3. Considerar eliminar blobs VHD originales para evitar cargos"
        Write-Log "4. Actualizar políticas de respaldo si es necesario"
        Write-Log "5. Las VMs pueden tener nuevas direcciones IP - actualizar dependencias"
    }
    else {
        Write-Log "Algunas migraciones fallaron. Por favor revisar el log para detalles." -Level "WARNING"
    }
}
catch {
    Write-Log "El script de migración falló: $($_.Exception.Message)" -Level "ERROR"
    Write-Log "Stack trace: $($_.Exception.StackTrace)" -Level "ERROR"
    exit 1
}
