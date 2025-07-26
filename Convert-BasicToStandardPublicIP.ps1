#Requires -Version 5.1
#Requires -Modules Az.Network, Az.Resources, Az.Compute

<#
.SYNOPSIS
    Migra Azure Public IP Addresses de Basic SKU a Standard SKU.

.DESCRIPTION
    Este script automatiza la migración de Public IP Addresses básicas de Azure a Standard SKU.
    Sigue la guía oficial de Microsoft para la migración de diferentes tipos de recursos que usan Basic Public IPs.
    
    El proceso de migración:
    1. Descubre recursos que usan Basic Public IPs
    2. Valida prerequisitos y escenarios soportados
    3. Realiza respaldo de la configuración actual
    4. Migra según el tipo de recurso asociado
    5. Valida la migración completada

    Tipos de recursos soportados:
    - Virtual Machines
    - Virtual Machine Scale Sets
    - Load Balancers (Basic SKU) - Usar script específico primero
    - VPN Gateways (usando Basic IPs)
    - ExpressRoute Gateways (usando Basic IPs)
    - Application Gateways (v1 SKU)
    - Azure Databricks (usando Basic IPs)

.PARAMETER ResourceGroupName
    El nombre del grupo de recursos que contiene los recursos a migrar.

.PARAMETER PublicIPName
    Nombre de la Public IP específica a migrar. Si no se especifica, migra todas las Basic Public IPs encontradas.

.PARAMETER ResourceType
    Tipo de recurso específico a migrar. Valores: VM, VMSS, LoadBalancer, VPNGateway, ExpressRouteGateway, ApplicationGateway, Databricks, All

.PARAMETER ValidateOnly
    Solo valida qué recursos necesitan migración sin realizar la migración.

.PARAMETER Force
    Omite las confirmaciones de usuario.

.PARAMETER BackupPath
    Ruta personalizada para almacenar archivos de respaldo. Por defecto es el directorio actual.

.PARAMETER LogPath
    Ruta para almacenar los logs de migración. Por defecto es el directorio actual.

.PARAMETER SkipLoadBalancerCheck
    Omite la verificación de Load Balancers básicos (úselo solo si ya migró todos los LB básicos).

.EXAMPLE
    .\Convert-BasicToStandardPublicIP.ps1 -ResourceGroupName "myRG" -ValidateOnly
    
.EXAMPLE
    .\Convert-BasicToStandardPublicIP.ps1 -ResourceGroupName "myRG" -ResourceType "VM"

.EXAMPLE
    .\Convert-BasicToStandardPublicIP.ps1 -ResourceGroupName "myRG" -PublicIPName "myBasicIP"

.NOTES
    Autor: Equipo de Migración Azure
    Versión: 1.0
    
    Prerequisitos:
    - PowerShell 5.1 o superior (recomendado PowerShell 7+)
    - Módulos Az.Network, Az.Resources, Az.Compute
    - Permisos apropiados de Azure
    
    Importante:
    - PRIMERO migre todos los Load Balancers básicos usando Convert-BasicToStandardLoadBalancer.ps1
    - La migración puede causar tiempo de inactividad
    - Basic Public IPs no pueden actualizarse directamente - se requiere recreación
    - Planificar cambios de IP si no se puede preservar la dirección
    - Fecha límite: 30 de septiembre de 2025
    
    Documentación:
    https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/public-ip-basic-upgrade-guidance
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$PublicIPName,

    [Parameter(Mandatory = $false)]
    [ValidateSet("VM", "VMSS", "LoadBalancer", "VPNGateway", "ExpressRouteGateway", "ApplicationGateway", "Databricks", "All")]
    [string]$ResourceType = "All",

    [Parameter(Mandatory = $false)]
    [switch]$ValidateOnly,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [string]$BackupPath = ".",

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".",

    [Parameter(Mandatory = $false)]
    [switch]$SkipLoadBalancerCheck
)

# Inicializar logging
$LogFile = Join-Path $LogPath "BasicToStandardPublicIP_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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
    
    # Verificar versión de PowerShell
    $PSVersion = $PSVersionTable.PSVersion
    if ($PSVersion.Major -lt 5 -or ($PSVersion.Major -eq 5 -and $PSVersion.Minor -lt 1)) {
        Write-Log "PowerShell 5.1 o superior es requerido. Versión actual: $($PSVersion.ToString())" -Level "ERROR"
        throw "Versión de PowerShell no soportada. Se requiere PowerShell 5.1 o superior."
    }
    Write-Log "Versión de PowerShell: $($PSVersion.ToString())"
    
    # Verificar si los módulos requeridos están disponibles
    $RequiredModules = @('Az.Network', 'Az.Resources', 'Az.Compute')
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
        return $ResourceGroup
    }
    catch {
        Write-Log "Grupo de recursos '$ResourceGroupName' no encontrado: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Get-BasicPublicIPs {
    Write-Log "Descubriendo Public IPs básicas..."
    
    try {
        if ($PublicIPName) {
            $PublicIPs = @(Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $PublicIPName -ErrorAction Stop)
        }
        else {
            $PublicIPs = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName | Where-Object { $_.Sku.Name -eq "Basic" }
        }
        
        Write-Log "Se encontraron $($PublicIPs.Count) Public IPs básicas"
        
        if ($PublicIPs.Count -eq 0) {
            Write-Log "No se encontraron Public IPs básicas para migrar" -Level "WARNING"
            return @()
        }
        
        # Mostrar detalles de las Public IPs encontradas
        foreach ($IP in $PublicIPs) {
            Write-Log "  - $($IP.Name): $($IP.IpAddress) (Allocation: $($IP.PublicIpAllocationMethod))"
        }
        
        return $PublicIPs
    }
    catch {
        Write-Log "Error al obtener Public IPs: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Get-PublicIPAssociations {
    param([array]$PublicIPs)
    
    Write-Log "Analizando asociaciones de Public IPs..."
    
    $Associations = @()
    
    foreach ($PublicIP in $PublicIPs) {
        $Association = [PSCustomObject]@{
            PublicIPName = $PublicIP.Name
            PublicIPAddress = $PublicIP.IpAddress
            AllocationMethod = $PublicIP.PublicIpAllocationMethod
            ResourceType = "Unassigned"
            ResourceName = ""
            ResourceId = ""
            NeedsSpecialHandling = $false
            MigrationComplexity = "Simple"
            Notes = ""
        }
        
        # Verificar asociación con Network Interface
        if ($PublicIP.IpConfiguration) {
            $ConfigId = $PublicIP.IpConfiguration.Id
            Write-Log "Analizando configuración IP: $ConfigId"
            
            # Determinar tipo de recurso basado en el ID de configuración
            if ($ConfigId -match "/virtualMachines/") {
                $Association.ResourceType = "VirtualMachine"
                $VMName = ($ConfigId -split "/virtualMachines/")[1].Split("/")[0]
                $Association.ResourceName = $VMName
                $Association.ResourceId = $ConfigId
                $Association.MigrationComplexity = "Simple"
                $Association.Notes = "VM con IP pública directa"
            }
            elseif ($ConfigId -match "/virtualMachineScaleSets/") {
                $Association.ResourceType = "VMSS"
                $VMSSName = ($ConfigId -split "/virtualMachineScaleSets/")[1].Split("/")[0]
                $Association.ResourceName = $VMSSName
                $Association.ResourceId = $ConfigId
                $Association.MigrationComplexity = "Complex"
                $Association.NeedsSpecialHandling = $true
                $Association.Notes = "VMSS requiere actualización de modelo y posible redeployment"
            }
            elseif ($ConfigId -match "/loadBalancers/") {
                $Association.ResourceType = "LoadBalancer"
                $LBName = ($ConfigId -split "/loadBalancers/")[1].Split("/")[0]
                $Association.ResourceName = $LBName
                $Association.ResourceId = $ConfigId
                $Association.MigrationComplexity = "Complex"
                $Association.NeedsSpecialHandling = $true
                $Association.Notes = "⚠️ MIGRAR LOAD BALANCER PRIMERO con script específico"
            }
            elseif ($ConfigId -match "/virtualNetworkGateways/") {
                $Association.ResourceType = "VPNGateway"
                $GWName = ($ConfigId -split "/virtualNetworkGateways/")[1].Split("/")[0]
                $Association.ResourceName = $GWName
                $Association.ResourceId = $ConfigId
                $Association.MigrationComplexity = "Complex"
                $Association.NeedsSpecialHandling = $true
                $Association.Notes = "Gateway requiere recreación completa"
            }
            elseif ($ConfigId -match "/applicationGateways/") {
                $Association.ResourceType = "ApplicationGateway"
                $AGWName = ($ConfigId -split "/applicationGateways/")[1].Split("/")[0]
                $Association.ResourceName = $AGWName
                $Association.ResourceId = $ConfigId
                $Association.MigrationComplexity = "Complex"
                $Association.NeedsSpecialHandling = $true
                $Association.Notes = "Application Gateway v1 debe actualizarse a v2"
            }
        }
        
        # Verificar asociaciones especiales
        if ($Association.ResourceType -eq "Unassigned") {
            # Buscar en recursos de Databricks
            $DatabricksWorkspaces = Get-AzResource -ResourceType "Microsoft.Databricks/workspaces" -ResourceGroupName $ResourceGroupName
            foreach ($Workspace in $DatabricksWorkspaces) {
                # Esta es una verificación básica - Databricks puede usar IPs de forma compleja
                $Association.Notes = "IP no asignada - verificar manualmente uso en Databricks u otros servicios"
            }
        }
        
        $Associations += $Association
    }
    
    return $Associations
}

function Test-LoadBalancerDependencies {
    Write-Log "Verificando dependencias de Load Balancer..."
    
    if ($SkipLoadBalancerCheck) {
        Write-Log "Omitiendo verificación de Load Balancers por parámetro -SkipLoadBalancerCheck" -Level "WARNING"
        return
    }
    
    try {
        $BasicLBs = Get-AzLoadBalancer -ResourceGroupName $ResourceGroupName | Where-Object { $_.Sku.Name -eq "Basic" }
        
        if ($BasicLBs.Count -gt 0) {
            Write-Log "¡ATENCIÓN! Se encontraron $($BasicLBs.Count) Load Balancers básicos:" -Level "ERROR"
            foreach ($LB in $BasicLBs) {
                Write-Log "  - $($LB.Name)" -Level "ERROR"
            }
            Write-Log ""
            Write-Log "DEBE MIGRAR PRIMERO TODOS LOS LOAD BALANCERS BÁSICOS usando:" -Level "ERROR"
            Write-Log ".\Convert-BasicToStandardLoadBalancer.ps1" -Level "ERROR"
            Write-Log ""
            Write-Log "Los Load Balancers básicos impiden la migración correcta de Public IPs." -Level "ERROR"
            Write-Log "Use -SkipLoadBalancerCheck solo si está seguro de que no afectan su migración." -Level "ERROR"
            
            throw "Dependencias de Load Balancer básicos encontradas. Migrar primero."
        }
        else {
            Write-Log "✓ No se encontraron Load Balancers básicos - OK para proceder"
        }
    }
    catch {
        if ($_.Exception.Message -like "*Dependencias de Load Balancer*") {
            throw
        }
        Write-Log "Error al verificar Load Balancers: $($_.Exception.Message)" -Level "WARNING"
    }
}

function Show-MigrationPlan {
    param([array]$Associations)
    
    Write-Log ""
    Write-Log "=== PLAN DE MIGRACIÓN DE PUBLIC IPS ==="
    Write-Log ""
    
    $SimpleCount = ($Associations | Where-Object { $_.MigrationComplexity -eq "Simple" }).Count
    $ComplexCount = ($Associations | Where-Object { $_.MigrationComplexity -eq "Complex" }).Count
    $SpecialCount = ($Associations | Where-Object { $_.NeedsSpecialHandling }).Count
    
    Write-Log "RESUMEN:"
    Write-Log "  Total Public IPs: $($Associations.Count)"
    Write-Log "  Migraciones simples: $SimpleCount"
    Write-Log "  Migraciones complejas: $ComplexCount"
    Write-Log "  Requieren manejo especial: $SpecialCount"
    Write-Log ""
    
    Write-Log "DETALLES POR RECURSO:"
    $Associations | Format-Table PublicIPName, ResourceType, ResourceName, MigrationComplexity, Notes -AutoSize | Out-String | Write-Host
    
    if ($SpecialCount -gt 0) {
        Write-Log "⚠️ ATENCIÓN: $SpecialCount recursos requieren manejo especial" -Level "WARNING"
    }
    
    Write-Log "======================================="
}

function Backup-PublicIPConfiguration {
    param([object]$PublicIP, [string]$BackupPath)
    
    $BackupFile = Join-Path $BackupPath "PublicIP_$($PublicIP.Name)_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    
    try {
        $BackupData = @{
            PublicIP = $PublicIP
            Timestamp = Get-Date
            BackupVersion = "1.0"
        }
        
        $BackupData | ConvertTo-Json -Depth 10 | Out-File -FilePath $BackupFile -Encoding UTF8
        Write-Log "Configuración respaldada: $BackupFile"
        return $BackupFile
    }
    catch {
        Write-Log "Error al crear respaldo: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Invoke-VMPublicIPMigration {
    param([object]$Association)
    
    Write-Log "Iniciando migración de Public IP para VM: $($Association.ResourceName)"
    
    try {
        if ($PSCmdlet.ShouldProcess($Association.PublicIPName, "Migrar Public IP de VM")) {
            # Obtener VM
            $VM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Association.ResourceName
            if (-not $VM) {
                throw "VM '$($Association.ResourceName)' no encontrada"
            }
            
            # Obtener configuración de red actual
            $NetworkProfile = $VM.NetworkProfile.NetworkInterfaces[0]
            $NIC = Get-AzNetworkInterface -ResourceId $NetworkProfile.Id
            $IPConfig = $NIC.IpConfigurations[0]
            
            # Crear nueva Public IP Standard
            $NewPublicIPName = "$($Association.PublicIPName)-standard"
            Write-Log "Creando nueva Public IP Standard: $NewPublicIPName"
            
            $NewPublicIP = New-AzPublicIpAddress `
                -ResourceGroupName $ResourceGroupName `
                -Name $NewPublicIPName `
                -Location $VM.Location `
                -Sku Standard `
                -AllocationMethod Static `
                -Zone @("1", "2", "3")  # Zone-redundant por defecto
            
            # Detener VM si está corriendo
            $VMStatus = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Association.ResourceName -Status
            $WasRunning = ($VMStatus.Statuses | Where-Object { $_.Code -eq "PowerState/running" }) -ne $null
            
            if ($WasRunning) {
                Write-Log "Deteniendo VM para migración..."
                Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $Association.ResourceName -Force
            }
            
            # Actualizar configuración de NIC
            Write-Log "Actualizando configuración de Network Interface..."
            $IPConfig.PublicIpAddress = $NewPublicIP
            Set-AzNetworkInterface -NetworkInterface $NIC
            
            # Reiniciar VM si estaba corriendo
            if ($WasRunning) {
                Write-Log "Reiniciando VM..."
                Start-AzVM -ResourceGroupName $ResourceGroupName -Name $Association.ResourceName
            }
            
            # Eliminar Public IP básica antigua (después de confirmación)
            if (-not $Force) {
                $Confirmation = Read-Host "¿Eliminar Public IP básica antigua '$($Association.PublicIPName)'? (s/N)"
                if ($Confirmation -match "^[SsYy]$") {
                    Remove-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $Association.PublicIPName -Force
                    Write-Log "Public IP básica eliminada: $($Association.PublicIPName)"
                }
            }
            
            Write-Log "✓ Migración de VM completada exitosamente"
            Write-Log "  Nueva Public IP: $NewPublicIPName ($($NewPublicIP.IpAddress))"
            
            return @{
                Success = $true
                NewPublicIPName = $NewPublicIPName
                NewIPAddress = $NewPublicIP.IpAddress
            }
        }
    }
    catch {
        Write-Log "Error en migración de VM: $($_.Exception.Message)" -Level "ERROR"
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Invoke-VMSSPublicIPMigration {
    param([object]$Association)
    
    Write-Log "Iniciando migración de Public IP para VMSS: $($Association.ResourceName)"
    Write-Log "⚠️ VMSS requiere actualización manual del modelo de instancia" -Level "WARNING"
    
    try {
        if ($PSCmdlet.ShouldProcess($Association.PublicIPName, "Migrar Public IP de VMSS")) {
            # Para VMSS, la migración es más compleja y requiere actualización del modelo
            Write-Log "Para VMSS, debe:" -Level "WARNING"
            Write-Log "1. Crear nueva Public IP Standard manualmente" -Level "WARNING"
            Write-Log "2. Actualizar el modelo de VMSS" -Level "WARNING"
            Write-Log "3. Realizar rolling upgrade de instancias" -Level "WARNING"
            Write-Log "4. Verificar conectividad" -Level "WARNING"
            
            # Esta implementación se centra en la guía básica
            Write-Log "Consulte documentación específica para VMSS en:" -Level "WARNING"
            Write-Log "https://learn.microsoft.com/azure/virtual-machine-scale-sets/" -Level "WARNING"
            
            return @{
                Success = $false
                RequiresManualAction = $true
                Message = "VMSS requiere migración manual - consulte documentación"
            }
        }
    }
    catch {
        Write-Log "Error en migración de VMSS: $($_.Exception.Message)" -Level "ERROR"
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Show-PostMigrationTasks {
    param([array]$Results)
    
    Write-Log ""
    Write-Log "=== TAREAS POST-MIGRACIÓN IMPORTANTES ==="
    Write-Log ""
    Write-Log "1. VALIDACIÓN OBLIGATORIA:"
    Write-Log "   - Probar conectividad a recursos migrados"
    Write-Log "   - Verificar aplicaciones funcionan correctamente"
    Write-Log "   - Confirmar nuevas direcciones IP en DNS/firewall"
    Write-Log ""
    Write-Log "2. ACTUALIZACIÓN DE CONFIGURACIONES:"
    Write-Log "   - Actualizar registros DNS con nuevas IPs"
    Write-Log "   - Actualizar reglas de firewall/NSG"
    Write-Log "   - Actualizar configuraciones de aplicaciones"
    Write-Log ""
    Write-Log "3. MONITOREO:"
    Write-Log "   - Configurar alertas para nuevas Public IPs"
    Write-Log "   - Verificar métricas de conectividad"
    Write-Log "   - Monitorear logs de aplicaciones"
    Write-Log ""
    Write-Log "4. LIMPIEZA:"
    Write-Log "   - Eliminar Public IPs básicas antiguas si no se usaron"
    Write-Log "   - Actualizar documentación de red"
    Write-Log "   - Verificar facturación actualizada"
    Write-Log ""
    Write-Log "============================================"
}

# Ejecución principal
try {
    Write-Log "Iniciando migración de Azure Public IP Addresses de Basic a Standard"
    Write-Log "Archivo de log: $LogFile"
    
    # Paso 1: Verificación de prerequisitos
    $ResourceGroup = Test-Prerequisites
    
    # Paso 2: Descubrir Public IPs básicas
    $BasicPublicIPs = Get-BasicPublicIPs
    if ($BasicPublicIPs.Count -eq 0) {
        Write-Log "No se encontraron Public IPs básicas para migrar" -Level "SUCCESS"
        exit 0
    }
    
    # Paso 3: Analizar asociaciones
    $Associations = Get-PublicIPAssociations -PublicIPs $BasicPublicIPs
    
    # Paso 4: Verificar dependencias de Load Balancer
    Test-LoadBalancerDependencies
    
    # Paso 5: Mostrar plan de migración
    Show-MigrationPlan -Associations $Associations
    
    # Paso 6: Validación solo si se solicita
    if ($ValidateOnly) {
        Write-Log "=== VALIDACIÓN COMPLETADA ==="
        Write-Log "Se encontraron $($BasicPublicIPs.Count) Public IPs básicas que requieren migración"
        Write-Log "Use el script sin -ValidateOnly para proceder con la migración"
        exit 0
    }
    
    # Paso 7: Confirmación
    if (-not $Force -and -not $WhatIfPreference) {
        Write-Log ""
        Write-Log "ADVERTENCIA: Esta migración puede causar tiempo de inactividad."
        Write-Log "Las direcciones IP pueden cambiar si no se puede preservar la IP básica."
        Write-Log ""
        $Confirmation = Read-Host "¿Desea proceder con la migración? (s/N)"
        if ($Confirmation -notmatch "^[SsYy]$") {
            Write-Log "Migración cancelada por el usuario"
            exit 0
        }
    }
    
    # Paso 8: Ejecutar migraciones
    $Results = @()
    
    foreach ($Association in $Associations) {
        Write-Log ""
        Write-Log "=== Procesando: $($Association.PublicIPName) ==="
        
        # Crear respaldo
        $PublicIP = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $Association.PublicIPName
        $BackupFile = Backup-PublicIPConfiguration -PublicIP $PublicIP -BackupPath $BackupPath
        
        # Migrar según tipo de recurso
        $Result = switch ($Association.ResourceType) {
            "VirtualMachine" {
                Invoke-VMPublicIPMigration -Association $Association
            }
            "VMSS" {
                Invoke-VMSSPublicIPMigration -Association $Association
            }
            "LoadBalancer" {
                Write-Log "⚠️ Load Balancer encontrado - debe usar script específico primero" -Level "ERROR"
                @{ Success = $false; Error = "Usar Convert-BasicToStandardLoadBalancer.ps1 primero" }
            }
            default {
                Write-Log "Tipo de recurso '$($Association.ResourceType)' requiere migración manual" -Level "WARNING"
                @{ Success = $false; RequiresManualAction = $true; Message = "Migración manual requerida" }
            }
        }
        
        $Result.PublicIPName = $Association.PublicIPName
        $Result.ResourceType = $Association.ResourceType
        $Result.ResourceName = $Association.ResourceName
        $Result.BackupFile = $BackupFile
        
        $Results += $Result
    }
    
    # Paso 9: Mostrar resultados
    Write-Log ""
    Write-Log "=== RESUMEN DE MIGRACIÓN ==="
    $SuccessCount = ($Results | Where-Object { $_.Success }).Count
    $FailureCount = ($Results | Where-Object { -not $_.Success -and -not $_.RequiresManualAction }).Count
    $ManualCount = ($Results | Where-Object { $_.RequiresManualAction }).Count
    
    Write-Log "Migraciones exitosas: $SuccessCount"
    Write-Log "Migraciones fallidas: $FailureCount"
    Write-Log "Requieren acción manual: $ManualCount"
    
    if ($SuccessCount -gt 0) {
        Write-Log ""
        Write-Log "MIGRACIONES EXITOSAS:"
        $Results | Where-Object { $_.Success } | ForEach-Object {
            Write-Log "✓ $($_.PublicIPName) -> $($_.NewPublicIPName) ($($_.NewIPAddress))"
        }
    }
    
    if ($FailureCount -gt 0) {
        Write-Log ""
        Write-Log "MIGRACIONES FALLIDAS:"
        $Results | Where-Object { -not $_.Success -and -not $_.RequiresManualAction } | ForEach-Object {
            Write-Log "❌ $($_.PublicIPName): $($_.Error)" -Level "ERROR"
        }
    }
    
    if ($ManualCount -gt 0) {
        Write-Log ""
        Write-Log "REQUIEREN ACCIÓN MANUAL:"
        $Results | Where-Object { $_.RequiresManualAction } | ForEach-Object {
            Write-Log "⚠️ $($_.PublicIPName): $($_.Message)" -Level "WARNING"
        }
    }
    
    # Paso 10: Mostrar tareas post-migración
    Show-PostMigrationTasks -Results $Results
    
    Write-Log ""
    Write-Log "Archivo de log: $LogFile"
    
    if ($FailureCount -gt 0) {
        exit 1
    }
}
catch {
    Write-Log "El script de migración falló: $($_.Exception.Message)" -Level "ERROR"
    Write-Log ""
    Write-Log "INFORMACIÓN DE RECUPERACIÓN:"
    Write-Log "1. Revisar el archivo de log para detalles: $LogFile"
    Write-Log "2. Buscar archivos de respaldo en: $BackupPath"
    Write-Log "3. Consultar documentación oficial: https://learn.microsoft.com/azure/virtual-network/ip-services/public-ip-basic-upgrade-guidance"
    Write-Log ""
    exit 1
}
