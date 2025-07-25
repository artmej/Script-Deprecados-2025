#Requires -Version 5.1
#Requires -Modules Az.Network, Az.Resources

<#
.SYNOPSIS
    Migra Azure Load Balancers básicos a Standard Load Balancers.

.DESCRIPTION
    Este script automatiza la migración de Load Balancers básicos de Azure a Standard Load Balancers.
    Utiliza el módulo oficial de Microsoft 'AzureBasicLoadBalancerUpgrade' para realizar la migración.
    
    El proceso de migración:
    1. Valida prerequisitos y escenarios soportados
    2. Instala el módulo de migración si es necesario
    3. Realiza respaldo de la configuración actual
    4. Migra el Load Balancer básico a Standard
    5. Valida la migración completada

.PARAMETER ResourceGroupName
    El nombre del grupo de recursos que contiene el Load Balancer.

.PARAMETER BasicLoadBalancerName
    El nombre del Load Balancer básico a migrar.

.PARAMETER StandardLoadBalancerName
    El nombre del nuevo Standard Load Balancer. Si no se especifica, se reutiliza el nombre del Load Balancer básico.

.PARAMETER ValidateScenarioOnly
    Solo valida si el escenario es soportado para migración sin realizar la migración.

.PARAMETER WhatIf
    Muestra qué pasaría sin realizar realmente la migración.

.PARAMETER Force
    Omite las confirmaciones de usuario.

.PARAMETER RecoveryBackupPath
    Ruta personalizada para almacenar archivos de respaldo. Por defecto es el directorio actual.

.PARAMETER LogPath
    Ruta para almacenar los logs de migración. Por defecto es el directorio actual.

.PARAMETER SkipUpgradeNATPoolsToNATRules
    Omite la actualización de NAT Pools a NAT Rules.

.PARAMETER FollowLog
    Muestra los logs en tiempo real durante la migración.

.EXAMPLE
    .\Convert-BasicToStandardLoadBalancer.ps1 -ResourceGroupName "myRG" -BasicLoadBalancerName "myBasicLB"
    
.EXAMPLE
    .\Convert-BasicToStandardLoadBalancer.ps1 -ResourceGroupName "myRG" -BasicLoadBalancerName "myBasicLB" -StandardLoadBalancerName "myStandardLB"

.EXAMPLE
    .\Convert-BasicToStandardLoadBalancer.ps1 -ResourceGroupName "myRG" -BasicLoadBalancerName "myBasicLB" -ValidateScenarioOnly

.NOTES
    Autor: Equipo de Migración Azure
    Versión: 1.0
    
    Prerequisitos:
    - PowerShell 5.1 o superior (recomendado PowerShell 7+)
    - Módulo AzureBasicLoadBalancerUpgrade
    - Permisos apropiados de Azure
    - Load Balancer debe estar en escenario soportado
    
    Importante:
    - La migración causa tiempo de inactividad
    - La migración no es completamente reversible
    - Revisar escenarios no soportados antes de migrar
    - Planificar conectividad saliente para Load Balancers internos
    - Fecha límite: 30 de septiembre de 2025
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$BasicLoadBalancerName,

    [Parameter(Mandatory = $false)]
    [string]$StandardLoadBalancerName,

    [Parameter(Mandatory = $false)]
    [switch]$ValidateScenarioOnly,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [string]$RecoveryBackupPath = ".",

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".",

    [Parameter(Mandatory = $false)]
    [switch]$SkipUpgradeNATPoolsToNATRules,

    [Parameter(Mandatory = $false)]
    [switch]$FollowLog
)

# Inicializar logging
$LogFile = Join-Path $LogPath "BasicToStandardLBMigration_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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
    $RequiredModules = @('Az.Network', 'Az.Resources')
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
    
    # Validar Load Balancer básico
    try {
        $BasicLB = Get-AzLoadBalancer -ResourceGroupName $ResourceGroupName -Name $BasicLoadBalancerName -ErrorAction Stop
        if ($BasicLB.Sku.Name -ne "Basic") {
            Write-Log "El Load Balancer '$BasicLoadBalancerName' no es de SKU Basic. SKU actual: $($BasicLB.Sku.Name)" -Level "ERROR"
            throw "El Load Balancer especificado no es de SKU Basic"
        }
        Write-Log "Load Balancer básico '$BasicLoadBalancerName' encontrado"
        return $BasicLB
    }
    catch {
        Write-Log "Load Balancer básico '$BasicLoadBalancerName' no encontrado: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Install-MigrationModule {
    Write-Log "Verificando módulo de migración AzureBasicLoadBalancerUpgrade..."
    
    # Verificar si el módulo está instalado
    $MigrationModule = Get-Module -ListAvailable -Name "AzureBasicLoadBalancerUpgrade"
    
    if (-not $MigrationModule) {
        Write-Log "Módulo AzureBasicLoadBalancerUpgrade no encontrado. Instalando..."
        
        try {
            if ($PSCmdlet.ShouldProcess("AzureBasicLoadBalancerUpgrade", "Instalar módulo de migración")) {
                Install-Module -Name AzureBasicLoadBalancerUpgrade -Scope CurrentUser -Repository PSGallery -Force
                Write-Log "Módulo AzureBasicLoadBalancerUpgrade instalado exitosamente"
            }
        }
        catch {
            Write-Log "Error al instalar módulo AzureBasicLoadBalancerUpgrade: $($_.Exception.Message)" -Level "ERROR"
            throw "No se pudo instalar el módulo de migración requerido"
        }
    }
    else {
        Write-Log "Módulo AzureBasicLoadBalancerUpgrade ya está instalado. Versión: $($MigrationModule.Version)"
    }
    
    # Importar el módulo
    try {
        Import-Module AzureBasicLoadBalancerUpgrade -Force
        Write-Log "Módulo AzureBasicLoadBalancerUpgrade importado exitosamente"
    }
    catch {
        Write-Log "Error al importar módulo AzureBasicLoadBalancerUpgrade: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Test-UnsupportedScenarios {
    param([object]$LoadBalancer)
    
    Write-Log "Verificando escenarios no soportados..."
    
    $UnsupportedIssues = @()
    
    # Verificar configuraciones IPv6
    $IPv6Configs = $LoadBalancer.FrontendIpConfigurations | Where-Object { $_.PrivateIpAddressVersion -eq "IPv6" }
    if ($IPv6Configs) {
        $UnsupportedIssues += "Load Balancer tiene configuraciones frontend IPv6"
    }
    
    # Verificar backend pools para AKS
    foreach ($BackendPool in $LoadBalancer.BackendAddressPools) {
        if ($BackendPool.Name -like "*kubernetes*" -or $BackendPool.Name -like "*aks*") {
            $UnsupportedIssues += "Posible Load Balancer de AKS detectado (no soportado)"
        }
    }
    
    # Verificar floating IP en configuraciones secundarias
    foreach ($Rule in $LoadBalancer.LoadBalancingRules) {
        if ($Rule.EnableFloatingIP -and $Rule.FrontendIPConfiguration) {
            # Esta es una verificación básica - se requiere validación manual más detallada
            Write-Log "Detectada regla con Floating IP habilitado: $($Rule.Name)" -Level "WARNING"
        }
    }
    
    if ($UnsupportedIssues.Count -gt 0) {
        Write-Log "ESCENARIOS NO SOPORTADOS DETECTADOS:" -Level "ERROR"
        foreach ($Issue in $UnsupportedIssues) {
            Write-Log "- $Issue" -Level "ERROR"
        }
        throw "Load Balancer tiene configuraciones no soportadas para migración automática"
    }
    
    Write-Log "Verificación de escenarios no soportados completada - Load Balancer parece ser compatible"
}

function Show-PreMigrationChecklist {
    Write-Log "=== LISTA DE VERIFICACIÓN PRE-MIGRACIÓN ==="
    Write-Log "Antes de proceder, confirme que ha realizado las siguientes tareas:"
    Write-Log ""
    Write-Log "✓ Planificado tiempo de inactividad de la aplicación"
    Write-Log "✓ Desarrollado pruebas de conectividad entrante y saliente"
    Write-Log "✓ Planificado cambios de IP públicas en instancias de VMSS (si aplica)"
    Write-Log "✓ Removido todos los bloqueos del Load Balancer y recursos relacionados"
    Write-Log "✓ Confirmado permisos necesarios para eliminar/crear Load Balancers"
    Write-Log "✓ Preparado conectividad saliente para Load Balancers internos"
    Write-Log "✓ Creado/actualizado Network Security Groups si es necesario"
    Write-Log ""
    Write-Log "================================================"
}

function Show-MigrationSummary {
    param([object]$BasicLB)
    
    Write-Log "=== RESUMEN DE MIGRACIÓN ==="
    Write-Log "Load Balancer Básico: $($BasicLB.Name)"
    Write-Log "Grupo de Recursos: $ResourceGroupName"
    Write-Log "Ubicación: $($BasicLB.Location)"
    Write-Log "Tipo: $(if ($BasicLB.FrontendIpConfigurations[0].PublicIpAddress) { 'Público' } else { 'Interno' })"
    Write-Log "Configuraciones Frontend: $($BasicLB.FrontendIpConfigurations.Count)"
    Write-Log "Backend Pools: $($BasicLB.BackendAddressPools.Count)"
    Write-Log "Reglas de Load Balancing: $($BasicLB.LoadBalancingRules.Count)"
    Write-Log "Health Probes: $($BasicLB.Probes.Count)"
    Write-Log "Reglas NAT entrantes: $($BasicLB.InboundNatRules.Count)"
    Write-Log "Pools NAT entrantes: $($BasicLB.InboundNatPools.Count)"
    
    if ($StandardLoadBalancerName) {
        Write-Log "Nuevo nombre Standard LB: $StandardLoadBalancerName"
    }
    else {
        Write-Log "Nuevo nombre Standard LB: $($BasicLB.Name) (mismo nombre)"
    }
    
    Write-Log "Ruta de respaldo: $RecoveryBackupPath"
    Write-Log "=========================="
}

function Invoke-LoadBalancerMigration {
    param([object]$BasicLB)
    
    Write-Log "Iniciando migración de Load Balancer..."
    
    try {
        # Preparar parámetros de migración
        $MigrationParams = @{
            ResourceGroupName = $ResourceGroupName
            BasicLoadBalancerName = $BasicLoadBalancerName
            RecoveryBackupPath = $RecoveryBackupPath
        }
        
        # Agregar parámetros opcionales
        if ($StandardLoadBalancerName) {
            $MigrationParams.StandardLoadBalancerName = $StandardLoadBalancerName
        }
        
        if ($SkipUpgradeNATPoolsToNATRules) {
            $MigrationParams.skipUpgradeNATPoolsToNATRules = $true
        }
        
        if ($FollowLog) {
            $MigrationParams.FollowLog = $true
        }
        
        if ($ValidateScenarioOnly) {
            $MigrationParams.validateScenarioOnly = $true
            Write-Log "Ejecutando solo validación de escenario..."
        }
        else {
            Write-Log "Ejecutando migración completa..."
        }
        
        # Ejecutar migración
        if ($PSCmdlet.ShouldProcess($BasicLoadBalancerName, "Migrar Load Balancer básico a Standard")) {
            Write-Log "Ejecutando Start-AzBasicLoadBalancerUpgrade con parámetros:"
            foreach ($Param in $MigrationParams.GetEnumerator()) {
                Write-Log "  $($Param.Key): $($Param.Value)"
            }
            
            $MigrationResult = Start-AzBasicLoadBalancerUpgrade @MigrationParams
            
            if ($ValidateScenarioOnly) {
                Write-Log "Validación de escenario completada exitosamente" -Level "SUCCESS"
                return $MigrationResult
            }
            else {
                Write-Log "Migración de Load Balancer completada exitosamente" -Level "SUCCESS"
                return $MigrationResult
            }
        }
    }
    catch {
        Write-Log "Error durante la migración: $($_.Exception.Message)" -Level "ERROR"
        
        # Proporcionar información de recuperación
        $BackupFiles = Get-ChildItem -Path $RecoveryBackupPath -Filter "State_$($BasicLoadBalancerName)_*" | Sort-Object LastWriteTime -Descending
        if ($BackupFiles) {
            Write-Log "Archivos de respaldo encontrados para recuperación:" -Level "WARNING"
            foreach ($BackupFile in $BackupFiles | Select-Object -First 3) {
                Write-Log "  $($BackupFile.FullName)" -Level "WARNING"
            }
            Write-Log "Para recuperar, use el parámetro -FailedMigrationRetryFilePathLB con el archivo más reciente" -Level "WARNING"
        }
        
        throw
    }
}

function Test-MigrationResult {
    param([string]$StandardLBName)
    
    Write-Log "Validando resultado de migración..."
    
    try {
        # Verificar que el Standard Load Balancer existe
        $StandardLB = Get-AzLoadBalancer -ResourceGroupName $ResourceGroupName -Name $StandardLBName -ErrorAction Stop
        
        if ($StandardLB.Sku.Name -ne "Standard") {
            Write-Log "ERROR: El Load Balancer migrado no es de SKU Standard" -Level "ERROR"
            return $false
        }
        
        Write-Log "✓ Standard Load Balancer creado exitosamente"
        Write-Log "✓ SKU confirmado como Standard"
        Write-Log "✓ Configuraciones Frontend: $($StandardLB.FrontendIpConfigurations.Count)"
        Write-Log "✓ Backend Pools: $($StandardLB.BackendAddressPools.Count)"
        Write-Log "✓ Reglas de Load Balancing: $($StandardLB.LoadBalancingRules.Count)"
        Write-Log "✓ Health Probes: $($StandardLB.Probes.Count)"
        
        # Verificar outbound rules para Load Balancers públicos
        if ($StandardLB.FrontendIpConfigurations[0].PublicIpAddress) {
            if ($StandardLB.OutboundRules.Count -gt 0) {
                Write-Log "✓ Reglas de salida configuradas: $($StandardLB.OutboundRules.Count)"
            }
            else {
                Write-Log "⚠ No se encontraron reglas de salida (pueden ser necesarias)" -Level "WARNING"
            }
        }
        
        return $true
    }
    catch {
        Write-Log "Error al validar migración: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Show-PostMigrationTasks {
    param([string]$StandardLBName, [bool]$IsPublic)
    
    Write-Log ""
    Write-Log "=== TAREAS POST-MIGRACIÓN IMPORTANTES ==="
    Write-Log ""
    Write-Log "1. VALIDACIÓN OBLIGATORIA:"
    Write-Log "   - Probar conectividad entrante a través del Load Balancer"
    Write-Log "   - Probar conectividad saliente desde miembros del backend pool"
    Write-Log "   - Verificar que todas las aplicaciones funcionen correctamente"
    Write-Log ""
    Write-Log "2. CONFIGURACIÓN DE CONECTIVIDAD SALIENTE:"
    if ($IsPublic) {
        Write-Log "   - Para Load Balancer público con múltiples backend pools:"
        Write-Log "     * Crear reglas de salida para cada backend pool"
        Write-Log "     * Configurar asignación de puertos apropiada"
    }
    else {
        Write-Log "   - Para Load Balancer interno, configurar una de las siguientes opciones:"
        Write-Log "     * NAT Gateway (recomendado después de migrar todos los recursos básicos)"
        Write-Log "     * Network Virtual Appliance (Azure Firewall, etc.)"
        Write-Log "     * Load Balancer externo secundario para tráfico saliente"
        Write-Log "     * IPs públicas en VMs/VMSS (no recomendado)"
    }
    Write-Log ""
    Write-Log "3. SEGURIDAD:"
    Write-Log "   - Verificar Network Security Groups en recursos backend"
    Write-Log "   - Actualizar reglas de firewall si es necesario"
    Write-Log "   - Revisar políticas de acceso"
    Write-Log ""
    Write-Log "4. MONITOREO:"
    Write-Log "   - Configurar alertas para el nuevo Standard Load Balancer"
    Write-Log "   - Actualizar dashboards de monitoreo"
    Write-Log "   - Verificar métricas de rendimiento"
    Write-Log ""
    Write-Log "5. LIMPIEZA (si todo funciona correctamente):"
    Write-Log "   - Los recursos originales ya fueron migrados automáticamente"
    Write-Log "   - Verificar que no queden recursos básicos huérfanos"
    Write-Log ""
    Write-Log "============================================"
}

# Ejecución principal
try {
    Write-Log "Iniciando migración de Azure Load Balancer de Basic a Standard"
    Write-Log "Archivo de log: $LogFile"
    
    # Paso 1: Verificación de prerequisitos
    $BasicLB = Test-Prerequisites
    
    # Paso 2: Instalar módulo de migración
    Install-MigrationModule
    
    # Paso 3: Verificar escenarios no soportados
    Test-UnsupportedScenarios -LoadBalancer $BasicLB
    
    # Paso 4: Mostrar resumen de migración
    Show-MigrationSummary -BasicLB $BasicLB
    
    # Paso 5: Mostrar checklist pre-migración
    if (-not $ValidateScenarioOnly) {
        Show-PreMigrationChecklist
    }
    
    # Paso 6: Confirmación
    if (-not $Force -and -not $WhatIf -and -not $ValidateScenarioOnly) {
        Write-Log ""
        Write-Log "ADVERTENCIA: Esta migración causará tiempo de inactividad en su aplicación."
        Write-Log "La migración no es completamente reversible para Load Balancers públicos."
        Write-Log ""
        $Confirmation = Read-Host "¿Desea proceder con la migración? (s/N)"
        if ($Confirmation -notmatch "^[SsYy]$") {
            Write-Log "Migración cancelada por el usuario"
            return
        }
    }
    
    # Paso 7: Ejecutar migración
    $MigrationResult = Invoke-LoadBalancerMigration -BasicLB $BasicLB
    
    if ($ValidateScenarioOnly) {
        Write-Log "=== VALIDACIÓN COMPLETADA ==="
        Write-Log "El Load Balancer '$BasicLoadBalancerName' es compatible para migración" -Level "SUCCESS"
        Write-Log "Puede proceder con la migración removiendo el parámetro -ValidateScenarioOnly"
    }
    else {
        # Paso 8: Validar resultado de migración
        $FinalLBName = if ($StandardLoadBalancerName) { $StandardLoadBalancerName } else { $BasicLoadBalancerName }
        $ValidationSuccess = Test-MigrationResult -StandardLBName $FinalLBName
        
        if ($ValidationSuccess) {
            Write-Log ""
            Write-Log "=== MIGRACIÓN COMPLETADA EXITOSAMENTE ==="
            Write-Log "Load Balancer '$BasicLoadBalancerName' migrado exitosamente a '$FinalLBName'" -Level "SUCCESS"
            
            # Determinar si es Load Balancer público
            $IsPublicLB = $BasicLB.FrontendIpConfigurations[0].PublicIpAddress -ne $null
            
            # Mostrar tareas post-migración
            Show-PostMigrationTasks -StandardLBName $FinalLBName -IsPublic $IsPublicLB
        }
        else {
            Write-Log "Migración completada pero la validación encontró problemas. Revisar configuración manualmente." -Level "WARNING"
        }
    }
    
    Write-Log "Archivo de log: $LogFile"
}
catch {
    Write-Log "El script de migración falló: $($_.Exception.Message)" -Level "ERROR"
    Write-Log ""
    Write-Log "INFORMACIÓN DE RECUPERACIÓN:"
    Write-Log "1. Revisar el archivo de log para detalles: $LogFile"
    Write-Log "2. Buscar archivos de respaldo en: $RecoveryBackupPath"
    Write-Log "3. Para recuperación, usar el cmdlet Start-AzBasicLoadBalancerUpgrade con parámetros de retry"
    Write-Log "4. Consultar documentación oficial: https://learn.microsoft.com/azure/load-balancer/"
    Write-Log ""
    exit 1
}
