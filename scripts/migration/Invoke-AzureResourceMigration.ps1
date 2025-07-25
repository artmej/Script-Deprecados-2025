#Requires -Version 5.1
#Requires -Modules Az.Resources, Az.Compute, Az.Network

<#
.SYNOPSIS
    Script maestro para migrar recursos de Azure basado en el ID del recurso.

.DESCRIPTION
    Este script procesa una lista de Resource IDs de Azure desde un archivo de texto
    y ejecuta automáticamente el script de migración apropiado para cada recurso.
    
    Tipos de recursos soportados y migraciones:
    - Virtual Machines con discos no administrados → Migra a discos administrados
    - Load Balancers con SKU Basic → Migra a Standard SKU
    - Public IP Addresses con SKU Basic → Migra a Standard SKU
    - Availability Sets no administrados → Migra a administrados
    
    El script determina automáticamente para cada recurso:
    1. El tipo de recurso
    2. Si necesita migración
    3. Qué script de migración ejecutar
    4. Los parámetros apropiados
    5. El orden correcto de migración

.PARAMETER ResourceIdFile
    Ruta al archivo de texto que contiene la lista de Resource IDs a migrar.
    Un Resource ID por línea. Líneas vacías y que empiecen con # son ignoradas.

.PARAMETER ResourceId
    El ID completo de un recurso específico de Azure a analizar y migrar.
    Formato: /subscriptions/{subscription-id}/resourceGroups/{rg-name}/providers/{provider}/{resource-type}/{resource-name}
    Se usa cuando se quiere migrar un solo recurso sin archivo.

.PARAMETER WhatIf
    Muestra qué migración se ejecutaría sin realizar cambios reales.

.PARAMETER Force
    Omite las confirmaciones de usuario en todos los scripts de migración.

.PARAMETER LogPath
    Ruta para almacenar los logs de migración. Por defecto es el directorio actual.

.PARAMETER SkipDependencyCheck
    Omite la verificación de dependencias entre recursos (úsese con precaución).

.PARAMETER MigrationScriptsPath
    Ruta donde se encuentran los scripts de migración. Por defecto es el directorio actual.

.EXAMPLE
    .\Invoke-AzureResourceMigration.ps1 -ResourceIdFile "recursos_a_migrar.txt"

.EXAMPLE
    .\Invoke-AzureResourceMigration.ps1 -ResourceIdFile "recursos_a_migrar.txt" -WhatIf

.EXAMPLE
    .\Invoke-AzureResourceMigration.ps1 -ResourceId "/subscriptions/12345/resourceGroups/myRG/providers/Microsoft.Compute/virtualMachines/myVM"

.EXAMPLE
    .\Invoke-AzureResourceMigration.ps1 -ResourceId "/subscriptions/12345/resourceGroups/myRG/providers/Microsoft.Network/loadBalancers/myLB" -WhatIf

.NOTES
    Autor: Equipo de Migración Azure
    Versión: 1.0
    
    Prerequisitos:
    - PowerShell 5.1 o superior
    - Módulos Az.Resources, Az.Compute, Az.Network
    - Scripts de migración en el directorio especificado
    - Permisos apropiados de Azure
    - Archivo de Resource IDs con formato correcto
    
    Formato del archivo de Resource IDs:
    # Este es un comentario
    /subscriptions/12345/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1
    /subscriptions/12345/resourceGroups/rg1/providers/Microsoft.Network/loadBalancers/lb1
    /subscriptions/12345/resourceGroups/rg2/providers/Microsoft.Network/publicIPAddresses/pip1
    
    Importante:
    - El script determina automáticamente el orden de migración correcto
    - Para Load Balancers, verifica dependencias de Public IPs
    - Para Public IPs, verifica que no existan Load Balancers Basic
    - Mantiene logs detallados de todo el proceso
    - Procesa los recursos en orden de prioridad automáticamente
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false, ParameterSetName = "FromFile")]
    [ValidateScript({Test-Path $_ -PathType Leaf})]
    [string]$ResourceIdFile,

    [Parameter(Mandatory = $false, ParameterSetName = "SingleResource")]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceId,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".",

    [Parameter(Mandatory = $false)]
    [switch]$SkipDependencyCheck,

    [Parameter(Mandatory = $false)]
    [string]$MigrationScriptsPath = $PSScriptRoot,

    [Parameter(Mandatory = $false)]
    [switch]$ContinueOnError
)

# Inicializar logging
$LogFile = Join-Path $LogPath "AzureResourceMigration_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Variables para scripts de migración
$DiskMigrationScript = Join-Path $MigrationScriptsPath "Convert-UnmanagedToManagedDisks.ps1"
$LoadBalancerMigrationScript = Join-Path $MigrationScriptsPath "Convert-BasicToStandardLoadBalancer.ps1"
$PublicIPMigrationScript = Join-Path $MigrationScriptsPath "Convert-BasicToStandardPublicIP.ps1"

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "[$Timestamp] [MASTER-$Level] $Message"
    Write-Host $LogMessage
    Add-Content -Path $LogFile -Value $LogMessage
}

function Read-ResourceIdFile {
    param([string]$FilePath)
    
    Write-Log "Leyendo archivo de Resource IDs: $FilePath"
    
    try {
        if (-not (Test-Path $FilePath)) {
            throw "Archivo no encontrado: $FilePath"
        }
        
        $ResourceIds = @()
        $LineNumber = 0
        
        Get-Content $FilePath | ForEach-Object {
            $LineNumber++
            $Line = $_.Trim()
            
            # Ignorar líneas vacías y comentarios
            if ($Line -and -not $Line.StartsWith('#')) {
                # Validar formato básico de Resource ID
                if ($Line -match '^/subscriptions/.+/resourceGroups/.+/providers/.+/.+/.+') {
                    $ResourceIds += [PSCustomObject]@{
                        ResourceId = $Line
                        LineNumber = $LineNumber
                        Source = $FilePath
                    }
                    Write-Log "  ✓ Línea $LineNumber : $Line"
                }
                else {
                    Write-Log "  ⚠️ Línea $LineNumber : Formato inválido - $Line" -Level "WARNING"
                }
            }
        }
        
        Write-Log "Se encontraron $($ResourceIds.Count) Resource IDs válidos en el archivo"
        return $ResourceIds
    }
    catch {
        Write-Log "Error leyendo archivo: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Sort-ResourcesByMigrationPriority {
    param([array]$Resources)
    
    Write-Log "Ordenando recursos por prioridad de migración..."
    
    # Evaluar cada recurso y asignar prioridad
    $PrioritizedResources = @()
    
    foreach ($ResourceInfo in $Resources) {
        try {
            $ParsedResource = Parse-ResourceId -ResourceId $ResourceInfo.ResourceId
            $Resource = Get-ResourceDetails -ParsedResource $ParsedResource
            $MigrationInfo = Test-ResourceNeedsMigration -ParsedResource $ParsedResource -Resource $Resource
            
            $PrioritizedResource = [PSCustomObject]@{
                ResourceId = $ResourceInfo.ResourceId
                LineNumber = $ResourceInfo.LineNumber
                Source = $ResourceInfo.Source
                ParsedResource = $ParsedResource
                Resource = $Resource
                MigrationInfo = $MigrationInfo
                Priority = $MigrationInfo.Priority
                ProcessingOrder = 0
            }
            
            $PrioritizedResources += $PrioritizedResource
        }
        catch {
            Write-Log "Error evaluando recurso '$($ResourceInfo.ResourceId)': $($_.Exception.Message)" -Level "ERROR"
            
            # Agregar recurso con prioridad de error
            $ErrorResource = [PSCustomObject]@{
                ResourceId = $ResourceInfo.ResourceId
                LineNumber = $ResourceInfo.LineNumber
                Source = $ResourceInfo.Source
                ParsedResource = $null
                Resource = $null
                MigrationInfo = [PSCustomObject]@{
                    NeedsMigration = $false
                    MigrationType = "Error"
                    Reason = "Error evaluando recurso: $($_.Exception.Message)"
                    Priority = 999
                }
                Priority = 999
                ProcessingOrder = 999
            }
            
            $PrioritizedResources += $ErrorResource
        }
    }
    
    # Ordenar por prioridad (1 = alta, 3 = baja, 999 = error)
    $SortedResources = $PrioritizedResources | Sort-Object Priority, LineNumber
    
    # Asignar orden de procesamiento
    for ($i = 0; $i -lt $SortedResources.Count; $i++) {
        $SortedResources[$i].ProcessingOrder = $i + 1
    }
    
    Write-Log "Orden de procesamiento determinado:"
    foreach ($Resource in $SortedResources) {
        $TypeInfo = if ($Resource.ParsedResource) { $Resource.ParsedResource.FullType } else { "Unknown" }
        $MigrationInfo = if ($Resource.MigrationInfo.NeedsMigration) { $Resource.MigrationInfo.MigrationType } else { "No necesita migración" }
        
        Write-Log "  $($Resource.ProcessingOrder). $($Resource.ParsedResource.ResourceName) ($TypeInfo) - $MigrationInfo"
    }
    
    return $SortedResources
}

function Invoke-BatchResourceMigration {
    param([array]$SortedResources)
    
    Write-Log "Iniciando migración por lotes de $($SortedResources.Count) recursos..."
    
    $Results = @()
    $SuccessCount = 0
    $SkippedCount = 0
    $FailureCount = 0
    
    foreach ($ResourceInfo in $SortedResources) {
        Write-Log ""
        Write-Log "=== PROCESANDO RECURSO $($ResourceInfo.ProcessingOrder)/$($SortedResources.Count) ==="
        Write-Log "Resource ID: $($ResourceInfo.ResourceId)"
        Write-Log "Línea: $($ResourceInfo.LineNumber)"
        
        $Result = [PSCustomObject]@{
            ResourceId = $ResourceInfo.ResourceId
            LineNumber = $ResourceInfo.LineNumber
            ResourceName = if ($ResourceInfo.ParsedResource) { $ResourceInfo.ParsedResource.ResourceName } else { "Unknown" }
            ResourceType = if ($ResourceInfo.ParsedResource) { $ResourceInfo.ParsedResource.FullType } else { "Unknown" }
            MigrationType = $ResourceInfo.MigrationInfo.MigrationType
            Success = $false
            Skipped = $false
            Error = $null
            ProcessingTime = Get-Date
        }
        
        try {
            # Verificar si el recurso necesita migración
            if (-not $ResourceInfo.MigrationInfo.NeedsMigration) {
                Write-Log "⏭️ Recurso no necesita migración: $($ResourceInfo.MigrationInfo.Reason)"
                $Result.Skipped = $true
                $Result.Success = $true
                $SkippedCount++
            }
            else {
                # Verificar dependencias
                $DependenciesOK = Test-MigrationDependencies -MigrationInfo $ResourceInfo.MigrationInfo -ParsedResource $ResourceInfo.ParsedResource
                
                if (-not $DependenciesOK) {
                    $ErrorMsg = "Dependencias no resueltas para migración"
                    Write-Log "❌ $ErrorMsg" -Level "ERROR"
                    $Result.Error = $ErrorMsg
                    $FailureCount++
                    
                    if (-not $ContinueOnError) {
                        Write-Log "Deteniendo procesamiento por error de dependencias" -Level "ERROR"
                        $Results += $Result
                        break
                    }
                }
                else {
                    # Ejecutar migración
                    $MigrationSuccess = Invoke-ResourceMigration -MigrationInfo $ResourceInfo.MigrationInfo -ParsedResource $ResourceInfo.ParsedResource
                    
                    if ($MigrationSuccess) {
                        Write-Log "✅ Migración exitosa"
                        $Result.Success = $true
                        $SuccessCount++
                    }
                    else {
                        Write-Log "❌ Migración fallida" -Level "ERROR"
                        $Result.Error = "Migración falló - revisar logs detallados"
                        $FailureCount++
                        
                        if (-not $ContinueOnError) {
                            Write-Log "Deteniendo procesamiento por error de migración" -Level "ERROR"
                            $Results += $Result
                            break
                        }
                    }
                }
            }
        }
        catch {
            Write-Log "Error procesando recurso: $($_.Exception.Message)" -Level "ERROR"
            $Result.Error = $_.Exception.Message
            $FailureCount++
            
            if (-not $ContinueOnError) {
                Write-Log "Deteniendo procesamiento por error crítico" -Level "ERROR"
                $Results += $Result
                break
            }
        }
        
        $Results += $Result
        
        # Pequeña pausa entre migraciones
        if ($ResourceInfo.ProcessingOrder -lt $SortedResources.Count) {
            Start-Sleep -Seconds 5
        }
    }
    
    Write-Log ""
    Write-Log "=== RESUMEN DE MIGRACIÓN POR LOTES ==="
    Write-Log "Total recursos procesados: $($Results.Count)"
    Write-Log "Migraciones exitosas: $SuccessCount"
    Write-Log "Recursos omitidos: $SkippedCount"
    Write-Log "Migraciones fallidas: $FailureCount"
    
    return $Results
}

function Show-BatchMigrationSummary {
    param([array]$Results)
    
    Write-Log ""
    Write-Log "======================================"
    Write-Log "   RESUMEN DETALLADO DE MIGRACIÓN    "
    Write-Log "======================================"
    Write-Log ""
    
    # Estadísticas generales
    $TotalResources = $Results.Count
    $SuccessfulMigrations = ($Results | Where-Object { $_.Success -and -not $_.Skipped }).Count
    $SkippedResources = ($Results | Where-Object { $_.Skipped }).Count
    $FailedMigrations = ($Results | Where-Object { -not $_.Success }).Count
    
    Write-Log "ESTADÍSTICAS GENERALES:"
    Write-Log "  Total recursos procesados: $TotalResources"
    Write-Log "  Migraciones exitosas: $SuccessfulMigrations"
    Write-Log "  Recursos omitidos (no necesitan migración): $SkippedResources"
    Write-Log "  Migraciones fallidas: $FailedMigrations"
    Write-Log ""
    
    # Detalles por recurso
    Write-Log "RESULTADOS DETALLADOS:"
    foreach ($Result in $Results) {
        $Status = if ($Result.Skipped) { "⏭️ OMITIDO" } elseif ($Result.Success) { "✅ EXITOSO" } else { "❌ FALLIDO" }
        Write-Log "  $Status - $($Result.ResourceName) ($($Result.ResourceType))"
        Write-Log "    Resource ID: $($Result.ResourceId)"
        Write-Log "    Línea: $($Result.LineNumber)"
        Write-Log "    Tipo migración: $($Result.MigrationType)"
        
        if ($Result.Error) {
            Write-Log "    Error: $($Result.Error)" -Level "ERROR"
        }
        Write-Log ""
    }
    
    # Archivos de log
    Write-Log "ARCHIVOS DE LOG:"
    Write-Log "  Log maestro: $LogFile"
    Write-Log "  Logs específicos: Buscar en directorio $LogPath"
    Write-Log ""
    
    # Recomendaciones
    if ($FailedMigrations -gt 0) {
        Write-Log "ACCIONES RECOMENDADAS:"
        Write-Log "1. 📋 Revisar logs detallados para recursos fallidos"
        Write-Log "2. 🔧 Resolver dependencias y problemas identificados"
        Write-Log "3. 🔄 Re-ejecutar script con solo los recursos fallidos"
        Write-Log "4. ✅ Validar funcionamiento de recursos migrados exitosamente"
    }
    else {
        Write-Log "🎉 TODAS LAS MIGRACIONES COMPLETADAS EXITOSAMENTE"
        Write-Log ""
        Write-Log "SIGUIENTES PASOS:"
        Write-Log "1. ✅ Validar funcionamiento de todos los recursos migrados"
        Write-Log "2. 📊 Verificar métricas y alertas en Azure"
        Write-Log "3. 📝 Actualizar documentación de recursos"
    }
    
    Write-Log ""
    Write-Log "======================================"
}
    Write-Log "Verificando prerequisitos maestros..."
    
    # Verificar módulos de Azure
    $RequiredModules = @('Az.Resources', 'Az.Compute', 'Az.Network')
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
    
    # Verificar que existen los scripts de migración
    $Scripts = @{
        "Discos" = $DiskMigrationScript
        "Load Balancer" = $LoadBalancerMigrationScript
        "Public IP" = $PublicIPMigrationScript
    }
    
    foreach ($Script in $Scripts.GetEnumerator()) {
        if (-not (Test-Path $Script.Value)) {
            Write-Log "Script de migración no encontrado: $($Script.Value)" -Level "ERROR"
            throw "Script de migración faltante para $($Script.Key): $($Script.Value)"
        }
    }
    
    Write-Log "✓ Prerequisitos verificados"
}

function Parse-ResourceId {
    param([string]$ResourceId)
    
    Write-Log "Analizando ID de recurso: $ResourceId"
    
    try {
        # Formato esperado: /subscriptions/{sub}/resourceGroups/{rg}/providers/{provider}/{type}/{name}
        $Parts = $ResourceId.Split('/')
        
        if ($Parts.Count -lt 8) {
            throw "Formato de Resource ID inválido"
        }
        
        $ParsedResource = [PSCustomObject]@{
            SubscriptionId = $Parts[2]
            ResourceGroupName = $Parts[4]
            Provider = $Parts[6]
            ResourceType = $Parts[7]
            ResourceName = $Parts[8]
            FullType = "$($Parts[6])/$($Parts[7])"
        }
        
        Write-Log "Recurso analizado:"
        Write-Log "  Suscripción: $($ParsedResource.SubscriptionId)"
        Write-Log "  Grupo de recursos: $($ParsedResource.ResourceGroupName)"
        Write-Log "  Tipo: $($ParsedResource.FullType)"
        Write-Log "  Nombre: $($ParsedResource.ResourceName)"
        
        return $ParsedResource
    }
    catch {
        Write-Log "Error analizando Resource ID: $($_.Exception.Message)" -Level "ERROR"
        throw "Resource ID inválido: $ResourceId"
    }
}

function Get-ResourceDetails {
    param([object]$ParsedResource)
    
    Write-Log "Obteniendo detalles del recurso..."
    
    try {
        $Resource = Get-AzResource -ResourceId $ResourceId -ErrorAction Stop
        
        Write-Log "Recurso encontrado:"
        Write-Log "  Nombre: $($Resource.Name)"
        Write-Log "  Tipo: $($Resource.ResourceType)"
        Write-Log "  Ubicación: $($Resource.Location)"
        Write-Log "  SKU: $($Resource.Sku.Name)"
        
        return $Resource
    }
    catch {
        Write-Log "Error obteniendo detalles del recurso: $($_.Exception.Message)" -Level "ERROR"
        throw "No se pudo obtener el recurso: $ResourceId"
    }
}

function Test-ResourceNeedsMigration {
    param(
        [object]$ParsedResource,
        [object]$Resource
    )
    
    Write-Log "Evaluando si el recurso necesita migración..."
    
    $MigrationInfo = [PSCustomObject]@{
        NeedsMigration = $false
        MigrationType = "None"
        Reason = ""
        Priority = 0
        Dependencies = @()
    }
    
    switch ($ParsedResource.FullType) {
        "Microsoft.Compute/virtualMachines" {
            # Verificar si la VM tiene discos no administrados
            try {
                $VM = Get-AzVM -ResourceGroupName $ParsedResource.ResourceGroupName -Name $ParsedResource.ResourceName
                
                if (-not $VM.StorageProfile.OsDisk.ManagedDisk) {
                    $MigrationInfo.NeedsMigration = $true
                    $MigrationInfo.MigrationType = "UnmanagedToManagedDisks"
                    $MigrationInfo.Reason = "VM usa discos no administrados"
                    $MigrationInfo.Priority = 1  # Alta prioridad - debe ir primero
                    
                    # Verificar si está en Availability Set
                    if ($VM.AvailabilitySetReference) {
                        $AvSetId = $VM.AvailabilitySetReference.Id
                        $MigrationInfo.Dependencies += $AvSetId
                        Write-Log "  Dependencia encontrada: Availability Set $AvSetId"
                    }
                }
                else {
                    $MigrationInfo.Reason = "VM ya usa discos administrados"
                    Write-Log "  ✓ VM ya usa discos administrados"
                }
            }
            catch {
                Write-Log "Error verificando VM: $($_.Exception.Message)" -Level "ERROR"
                throw
            }
        }
        
        "Microsoft.Network/loadBalancers" {
            # Verificar si el Load Balancer es Basic SKU
            try {
                $LB = Get-AzLoadBalancer -ResourceGroupName $ParsedResource.ResourceGroupName -Name $ParsedResource.ResourceName
                
                if ($LB.Sku.Name -eq "Basic") {
                    $MigrationInfo.NeedsMigration = $true
                    $MigrationInfo.MigrationType = "BasicToStandardLoadBalancer"
                    $MigrationInfo.Reason = "Load Balancer usa SKU Basic"
                    $MigrationInfo.Priority = 2  # Media prioridad - antes que Public IPs
                    
                    # Verificar Public IPs asociadas
                    foreach ($FrontendConfig in $LB.FrontendIpConfigurations) {
                        if ($FrontendConfig.PublicIpAddress) {
                            $PIPId = $FrontendConfig.PublicIpAddress.Id
                            $MigrationInfo.Dependencies += $PIPId
                            Write-Log "  Dependencia encontrada: Public IP $PIPId"
                        }
                    }
                }
                else {
                    $MigrationInfo.Reason = "Load Balancer ya usa SKU Standard"
                    Write-Log "  ✓ Load Balancer ya usa SKU Standard"
                }
            }
            catch {
                Write-Log "Error verificando Load Balancer: $($_.Exception.Message)" -Level "ERROR"
                throw
            }
        }
        
        "Microsoft.Network/publicIPAddresses" {
            # Verificar si la Public IP es Basic SKU
            try {
                $PIP = Get-AzPublicIpAddress -ResourceGroupName $ParsedResource.ResourceGroupName -Name $ParsedResource.ResourceName
                
                if ($PIP.Sku.Name -eq "Basic") {
                    $MigrationInfo.NeedsMigration = $true
                    $MigrationInfo.MigrationType = "BasicToStandardPublicIP"
                    $MigrationInfo.Reason = "Public IP usa SKU Basic"
                    $MigrationInfo.Priority = 3  # Baja prioridad - debe ir al final
                    
                    # Verificar si está asociada a Load Balancer Basic
                    if (-not $SkipDependencyCheck) {
                        $BasicLBs = Get-AzLoadBalancer -ResourceGroupName $ParsedResource.ResourceGroupName | 
                                   Where-Object { $_.Sku.Name -eq "Basic" }
                        
                        foreach ($LB in $BasicLBs) {
                            foreach ($FrontendConfig in $LB.FrontendIpConfigurations) {
                                if ($FrontendConfig.PublicIpAddress.Id -eq $ResourceId) {
                                    $MigrationInfo.Dependencies += $LB.Id
                                    Write-Log "  ⚠️ DEPENDENCIA CRÍTICA: Load Balancer Basic $($LB.Name) usa esta Public IP"
                                }
                            }
                        }
                    }
                }
                else {
                    $MigrationInfo.Reason = "Public IP ya usa SKU Standard"
                    Write-Log "  ✓ Public IP ya usa SKU Standard"
                }
            }
            catch {
                Write-Log "Error verificando Public IP: $($_.Exception.Message)" -Level "ERROR"
                throw
            }
        }
        
        "Microsoft.Compute/availabilitySets" {
            # Verificar si el Availability Set es no administrado
            try {
                $AvSet = Get-AzAvailabilitySet -ResourceGroupName $ParsedResource.ResourceGroupName -Name $ParsedResource.ResourceName
                
                if ($AvSet.Sku -ne "Aligned") {
                    $MigrationInfo.NeedsMigration = $true
                    $MigrationInfo.MigrationType = "UnmanagedToManagedAvailabilitySet"
                    $MigrationInfo.Reason = "Availability Set no es administrado"
                    $MigrationInfo.Priority = 1  # Alta prioridad - debe ir con VMs
                }
                else {
                    $MigrationInfo.Reason = "Availability Set ya es administrado"
                    Write-Log "  ✓ Availability Set ya es administrado"
                }
            }
            catch {
                Write-Log "Error verificando Availability Set: $($_.Exception.Message)" -Level "ERROR"
                throw
            }
        }
        
        default {
            $MigrationInfo.Reason = "Tipo de recurso no soportado para migración automática: $($ParsedResource.FullType)"
            Write-Log "  ⚠️ $($MigrationInfo.Reason)" -Level "WARNING"
        }
    }
    
    Write-Log "Evaluación de migración completada:"
    Write-Log "  Necesita migración: $($MigrationInfo.NeedsMigration)"
    Write-Log "  Tipo de migración: $($MigrationInfo.MigrationType)"
    Write-Log "  Razón: $($MigrationInfo.Reason)"
    Write-Log "  Prioridad: $($MigrationInfo.Priority)"
    Write-Log "  Dependencias: $($MigrationInfo.Dependencies.Count)"
    
    return $MigrationInfo
}

function Test-MigrationDependencies {
    param([object]$MigrationInfo, [object]$ParsedResource)
    
    if ($SkipDependencyCheck) {
        Write-Log "Omitiendo verificación de dependencias por parámetro -SkipDependencyCheck" -Level "WARNING"
        return $true
    }
    
    Write-Log "Verificando dependencias de migración..."
    
    # Para Public IPs, verificar que no hay Load Balancers Basic
    if ($MigrationInfo.MigrationType -eq "BasicToStandardPublicIP") {
        if ($MigrationInfo.Dependencies.Count -gt 0) {
            Write-Log "❌ DEPENDENCIAS CRÍTICAS ENCONTRADAS:" -Level "ERROR"
            foreach ($Dependency in $MigrationInfo.Dependencies) {
                Write-Log "  - $Dependency" -Level "ERROR"
            }
            Write-Log ""
            Write-Log "DEBE MIGRAR PRIMERO TODOS LOS LOAD BALANCERS BÁSICOS antes de migrar Public IPs" -Level "ERROR"
            Write-Log "Use el script: .\Convert-BasicToStandardLoadBalancer.ps1" -Level "ERROR"
            
            return $false
        }
    }
    
    Write-Log "✓ Verificación de dependencias completada"
    return $true
}

function Invoke-ResourceMigration {
    param(
        [object]$MigrationInfo,
        [object]$ParsedResource
    )
    
    Write-Log "Iniciando migración de recurso..."
    Write-Log "Tipo de migración: $($MigrationInfo.MigrationType)"
    
    try {
        switch ($MigrationInfo.MigrationType) {
            "UnmanagedToManagedDisks" {
                Write-Log "Ejecutando migración de discos no administrados a administrados..."
                
                $MigrationParams = @{
                    ResourceGroupName = $ParsedResource.ResourceGroupName
                    VMName = $ParsedResource.ResourceName
                    LogPath = $LogPath
                }
                
                if ($WhatIf) { $MigrationParams.WhatIf = $true }
                if ($Force) { $MigrationParams.Force = $true }
                
                Write-Log "Parámetros de migración: $(($MigrationParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
                
                & $DiskMigrationScript @MigrationParams
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "✅ Migración de discos completada exitosamente"
                    return $true
                }
                else {
                    Write-Log "❌ Migración de discos falló con código de salida: $LASTEXITCODE" -Level "ERROR"
                    return $false
                }
            }
            
            "BasicToStandardLoadBalancer" {
                Write-Log "Ejecutando migración de Load Balancer Basic a Standard..."
                
                $MigrationParams = @{
                    ResourceGroupName = $ParsedResource.ResourceGroupName
                    BasicLoadBalancerName = $ParsedResource.ResourceName
                    LogPath = $LogPath
                }
                
                if ($WhatIf) { $MigrationParams.ValidateScenarioOnly = $true }
                if ($Force) { $MigrationParams.Force = $true }
                
                Write-Log "Parámetros de migración: $(($MigrationParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
                
                & $LoadBalancerMigrationScript @MigrationParams
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "✅ Migración de Load Balancer completada exitosamente"
                    return $true
                }
                else {
                    Write-Log "❌ Migración de Load Balancer falló con código de salida: $LASTEXITCODE" -Level "ERROR"
                    return $false
                }
            }
            
            "BasicToStandardPublicIP" {
                Write-Log "Ejecutando migración de Public IP Basic a Standard..."
                
                $MigrationParams = @{
                    ResourceGroupName = $ParsedResource.ResourceGroupName
                    PublicIPName = $ParsedResource.ResourceName
                    LogPath = $LogPath
                    SkipLoadBalancerCheck = $SkipDependencyCheck
                }
                
                if ($WhatIf) { $MigrationParams.ValidateOnly = $true }
                if ($Force) { $MigrationParams.Force = $true }
                
                Write-Log "Parámetros de migración: $(($MigrationParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
                
                & $PublicIPMigrationScript @MigrationParams
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "✅ Migración de Public IP completada exitosamente"
                    return $true
                }
                else {
                    Write-Log "❌ Migración de Public IP falló con código de salida: $LASTEXITCODE" -Level "ERROR"
                    return $false
                }
            }
            
            default {
                Write-Log "Tipo de migración no implementado: $($MigrationInfo.MigrationType)" -Level "ERROR"
                return $false
            }
        }
    }
    catch {
        Write-Log "Error ejecutando migración: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Show-MigrationSummary {
    param(
        [object]$ParsedResource,
        [object]$MigrationInfo,
        [bool]$MigrationResult
    )
    
    Write-Log ""
    Write-Log "======================================"
    Write-Log "    RESUMEN DE MIGRACIÓN MAESTRO     "
    Write-Log "======================================"
    Write-Log ""
    Write-Log "RECURSO ANALIZADO:"
    Write-Log "  Nombre: $($ParsedResource.ResourceName)"
    Write-Log "  Tipo: $($ParsedResource.FullType)"
    Write-Log "  Grupo de recursos: $($ParsedResource.ResourceGroupName)"
    Write-Log ""
    Write-Log "MIGRACIÓN:"
    Write-Log "  Necesitaba migración: $($MigrationInfo.NeedsMigration)"
    Write-Log "  Tipo de migración: $($MigrationInfo.MigrationType)"
    Write-Log "  Razón: $($MigrationInfo.Reason)"
    
    if ($MigrationInfo.NeedsMigration) {
        $Status = if ($MigrationResult) { "✅ EXITOSA" } else { "❌ FALLIDA" }
        Write-Log "  Resultado: $Status"
    }
    
    Write-Log ""
    Write-Log "ARCHIVOS DE LOG:"
    Write-Log "  Log maestro: $LogFile"
    Write-Log "  Logs específicos: Buscar en directorio $LogPath"
    Write-Log ""
    Write-Log "======================================"
}

# Ejecución principal
try {
    # Verificar prerequisitos
    Test-Prerequisites
    
    if ($PSCmdlet.ParameterSetName -eq "FromFile") {
        Write-Log "======================================"
        Write-Log "  MIGRACIÓN POR LOTES DESDE ARCHIVO  "
        Write-Log "======================================"
        Write-Log ""
        Write-Log "Fecha/Hora: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Log "Archivo de entrada: $ResourceIdFile"
        Write-Log "Usuario: $env:USERNAME"
        Write-Log "Contexto: $((Get-AzContext).Account.Id)"
        Write-Log "Continuar en error: $ContinueOnError"
        Write-Log ""

        # Leer archivo de Resource IDs
        $ResourceIdList = Read-ResourceIdFile -FilePath $ResourceIdFile
        
        if ($ResourceIdList.Count -eq 0) {
            Write-Log "❌ No se encontraron Resource IDs válidos en el archivo." -Level "ERROR"
            exit 1
        }
        
        # Ordenar recursos por prioridad
        $SortedResources = Sort-ResourcesByMigrationPriority -Resources $ResourceIdList
        
        # Ejecutar migración por lotes
        $Results = Invoke-BatchResourceMigration -SortedResources $SortedResources
        
        # Mostrar resumen
        Show-BatchMigrationSummary -Results $Results
        
        # Determinar código de salida
        $FailedCount = ($Results | Where-Object { -not $_.Success }).Count
        if ($FailedCount -eq 0) {
            Write-Log "🎉 TODAS LAS MIGRACIONES POR LOTES COMPLETADAS EXITOSAMENTE" -Level "SUCCESS"
            exit 0
        }
        else {
            Write-Log "❌ $FailedCount MIGRACIONES FALLARON. REVISAR LOGS DETALLADOS." -Level "ERROR"
            exit 1
        }
    }
    else {
        # Migración de un solo recurso
        Write-Log "======================================"
        Write-Log "   MIGRACIÓN DE RECURSO INDIVIDUAL   "
        Write-Log "======================================"
        Write-Log ""
        Write-Log "Fecha/Hora: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Log "Resource ID: $ResourceId"
        Write-Log "Usuario: $env:USERNAME"
        Write-Log "Contexto: $((Get-AzContext).Account.Id)"
        Write-Log ""
        
        # Analizar Resource ID
        $ParsedResource = Parse-ResourceId -ResourceId $ResourceId
        
        # Obtener detalles del recurso
        $Resource = Get-ResourceDetails -ParsedResource $ParsedResource
        
        # Evaluar si necesita migración
        $MigrationInfo = Test-ResourceNeedsMigration -ParsedResource $ParsedResource -Resource $Resource
        
        # Verificar si no necesita migración
        if (-not $MigrationInfo.NeedsMigration) {
            Write-Log "El recurso no necesita migración: $($MigrationInfo.Reason)" -Level "SUCCESS"
            Show-MigrationSummary -ParsedResource $ParsedResource -MigrationInfo $MigrationInfo -MigrationResult $true
            exit 0
        }
        
        # Verificar dependencias
        $DependenciesOK = Test-MigrationDependencies -MigrationInfo $MigrationInfo -ParsedResource $ParsedResource
        if (-not $DependenciesOK) {
            Write-Log "No se puede proceder con la migración debido a dependencias no resueltas" -Level "ERROR"
            Show-MigrationSummary -ParsedResource $ParsedResource -MigrationInfo $MigrationInfo -MigrationResult $false
            exit 1
        }
        
        # Confirmación
        if (-not $Force -and -not $WhatIf) {
            Write-Log ""
            Write-Log "RESUMEN DE MIGRACIÓN A EJECUTAR:"
            Write-Log "  Recurso: $($ParsedResource.ResourceName)"
            Write-Log "  Tipo: $($MigrationInfo.MigrationType)"
            Write-Log "  Razón: $($MigrationInfo.Reason)"
            Write-Log ""
            
            $Confirmation = Read-Host "¿Desea proceder con la migración? (s/N)"
            if ($Confirmation -notmatch "^[SsYy]$") {
                Write-Log "Migración cancelada por el usuario"
                exit 0
            }
        }
        
        # Ejecutar migración
        Write-Log ""
        Write-Log "=== INICIANDO MIGRACIÓN ==="
        $MigrationResult = Invoke-ResourceMigration -MigrationInfo $MigrationInfo -ParsedResource $ParsedResource
        
        # Mostrar resumen final
        Show-MigrationSummary -ParsedResource $ParsedResource -MigrationInfo $MigrationInfo -MigrationResult $MigrationResult
        
        if ($MigrationResult) {
            Write-Log "🎉 MIGRACIÓN INDIVIDUAL COMPLETADA EXITOSAMENTE" -Level "SUCCESS"
            exit 0
        }
        else {
            Write-Log "❌ MIGRACIÓN INDIVIDUAL FALLÓ" -Level "ERROR"
            exit 1
        }
    }
}
catch {
    Write-Log "El script maestro de migración falló: $($_.Exception.Message)" -Level "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"
    Write-Log ""
    Write-Log "INFORMACIÓN DE RECUPERACIÓN:"
    Write-Log "1. Revisar el archivo de log para detalles: $LogFile"
    Write-Log "2. Ejecutar scripts de migración individuales si es necesario"
    Write-Log "3. Verificar permisos y conectividad a Azure"
    Write-Log "4. Si usó archivo, verificar formato de Resource IDs"
    Write-Log ""
    exit 1
}

Write-Log ""
Write-Log "======================================"
Write-Log "        MIGRACIÓN FINALIZADA         "
Write-Log "======================================"
Write-Log "Log completo guardado en: $LogFile"
Write-Log ""
