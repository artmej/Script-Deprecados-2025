#Requires -Version 5.1
#Requires -Modules Az.Resources

<#
.SYNOPSIS
    Script maestro para ejecutar todas las pruebas de migración de SKUs deprecados.

.DESCRIPTION
    Este script ejecuta todos los scripts de prueba en el orden correcto para validar
    el proceso completo de migración de SKUs deprecados en Azure.
    
    Ejecuta las pruebas en el orden correcto:
    1. Migración de discos no administrados a administrados
    2. Migración de Load Balancer Basic a Standard
    3. Migración de Public IP Basic a Standard

.PARAMETER Location
    Ubicación de Azure para crear los recursos de prueba.

.PARAMETER TestPrefix
    Prefijo para nombrar los grupos de recursos de prueba.

.PARAMETER SkipDiskTest
    Omitir la prueba de migración de discos.

.PARAMETER SkipLoadBalancerTest
    Omitir la prueba de migración de Load Balancer.

.PARAMETER SkipPublicIPTest
    Omitir la prueba de migración de Public IP.

.PARAMETER SkipCleanup
    No eliminar recursos después de las pruebas.

.PARAMETER ParallelExecution
    Ejecutar pruebas en paralelo (no recomendado para validación completa).

.EXAMPLE
    .\Run-AllMigrationTests.ps1 -Location "East US"

.EXAMPLE
    .\Run-AllMigrationTests.ps1 -Location "East US" -TestPrefix "qa" -SkipCleanup

.NOTES
    Este script es para PRUEBAS ÚNICAMENTE.
    Los recursos creados generarán costos en Azure.
    Se recomienda ejecutar en una suscripción de desarrollo/pruebas.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [string]$TestPrefix = "test",

    [Parameter(Mandatory = $false)]
    [switch]$SkipDiskTest,

    [Parameter(Mandatory = $false)]
    [switch]$SkipLoadBalancerTest,

    [Parameter(Mandatory = $false)]
    [switch]$SkipPublicIPTest,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCleanup,

    [Parameter(Mandatory = $false)]
    [switch]$ParallelExecution
)

# Variables globales
$TestScriptPath = $PSScriptRoot
$TestResults = @()
$StartTime = Get-Date

# Función para logging
function Write-TestLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "[$Timestamp] [MASTER-$Level] $Message"
    Write-Host $LogMessage
    
    # También escribir a archivo de log
    $LogFile = Join-Path $TestScriptPath "MasterTest_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    Add-Content -Path $LogFile -Value $LogMessage
}

function Test-Prerequisites {
    Write-TestLog "Verificando prerequisitos maestros..."
    
    # Verificar conexión a Azure
    $Context = Get-AzContext
    if (-not $Context) {
        throw "No conectado a Azure. Ejecutar Connect-AzAccount"
    }
    
    Write-TestLog "✓ Conectado a Azure:"
    Write-TestLog "  Suscripción: $($Context.Subscription.Name)"
    Write-TestLog "  Usuario: $($Context.Account.Id)"
    Write-TestLog "  Tenant: $($Context.Tenant.Id)"
    
    # Verificar que existen los scripts de prueba
    $TestScripts = @{
        "Disk" = "Test-DiskMigration.ps1"
        "LoadBalancer" = "Test-LoadBalancerMigration.ps1"
        "PublicIP" = "Test-PublicIPMigration.ps1"
    }
    
    foreach ($Script in $TestScripts.GetEnumerator()) {
        $ScriptPath = Join-Path $TestScriptPath $Script.Value
        if (-not (Test-Path $ScriptPath)) {
            throw "Script de prueba no encontrado: $ScriptPath"
        }
        Write-TestLog "✓ Script encontrado: $($Script.Key)"
    }
    
    # Verificar ubicación de Azure
    $AvailableLocations = Get-AzLocation | Select-Object -ExpandProperty Location
    if ($Location -notin $AvailableLocations) {
        throw "Ubicación '$Location' no es válida. Ubicaciones disponibles: $($AvailableLocations -join ', ')"
    }
    
    Write-TestLog "✓ Prerequisitos verificados"
    return $TestScripts
}

function New-TestResourceGroups {
    Write-TestLog "Generando nombres de grupos de recursos..."
    
    $Timestamp = Get-Date -Format "MMddHHmm"
    $ResourceGroups = @{
        "Disk" = "rg-$TestPrefix-disk-$Timestamp"
        "LoadBalancer" = "rg-$TestPrefix-lb-$Timestamp"
        "PublicIP" = "rg-$TestPrefix-pip-$Timestamp"
    }
    
    Write-TestLog "Grupos de recursos de prueba:"
    foreach ($RG in $ResourceGroups.GetEnumerator()) {
        Write-TestLog "  $($RG.Key): $($RG.Value)"
    }
    
    return $ResourceGroups
}

function Invoke-DiskMigrationTest {
    param(
        [string]$ResourceGroupName,
        [hashtable]$TestScripts
    )
    
    Write-TestLog "=== EJECUTANDO PRUEBA DE MIGRACIÓN DE DISCOS ==="
    
    try {
        $ScriptPath = Join-Path $TestScriptPath $TestScripts["Disk"]
        $TestParams = @{
            ResourceGroupName = $ResourceGroupName
            Location = $Location
            SkipCleanup = $SkipCleanup
        }
        
        Write-TestLog "Ejecutando: $ScriptPath"
        Write-TestLog "Parámetros: $(($TestParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
        
        $Result = & $ScriptPath @TestParams
        
        $TestResult = [PSCustomObject]@{
            TestType = "DiskMigration"
            ResourceGroup = $ResourceGroupName
            Success = $LASTEXITCODE -eq 0
            StartTime = Get-Date
            EndTime = Get-Date
            Duration = (Get-Date) - $StartTime
            ErrorMessage = if ($LASTEXITCODE -ne 0) { "Test failed with exit code $LASTEXITCODE" } else { $null }
        }
        
        if ($TestResult.Success) {
            Write-TestLog "✅ Prueba de discos EXITOSA"
        }
        else {
            Write-TestLog "❌ Prueba de discos FALLIDA" -Level "ERROR"
        }
        
        return $TestResult
    }
    catch {
        Write-TestLog "Error ejecutando prueba de discos: $($_.Exception.Message)" -Level "ERROR"
        
        return [PSCustomObject]@{
            TestType = "DiskMigration"
            ResourceGroup = $ResourceGroupName
            Success = $false
            StartTime = Get-Date
            EndTime = Get-Date
            Duration = New-TimeSpan
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Invoke-LoadBalancerMigrationTest {
    param(
        [string]$ResourceGroupName,
        [hashtable]$TestScripts
    )
    
    Write-TestLog "=== EJECUTANDO PRUEBA DE MIGRACIÓN DE LOAD BALANCER ==="
    
    try {
        $ScriptPath = Join-Path $TestScriptPath $TestScripts["LoadBalancer"]
        $TestParams = @{
            ResourceGroupName = $ResourceGroupName
            Location = $Location
            LoadBalancerType = "Public"  # Probar Load Balancer público
            SkipCleanup = $SkipCleanup
        }
        
        Write-TestLog "Ejecutando: $ScriptPath"
        Write-TestLog "Parámetros: $(($TestParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
        
        $Result = & $ScriptPath @TestParams
        
        $TestResult = [PSCustomObject]@{
            TestType = "LoadBalancerMigration"
            ResourceGroup = $ResourceGroupName
            Success = $LASTEXITCODE -eq 0
            StartTime = Get-Date
            EndTime = Get-Date
            Duration = (Get-Date) - $StartTime
            ErrorMessage = if ($LASTEXITCODE -ne 0) { "Test failed with exit code $LASTEXITCODE" } else { $null }
        }
        
        if ($TestResult.Success) {
            Write-TestLog "✅ Prueba de Load Balancer EXITOSA"
        }
        else {
            Write-TestLog "❌ Prueba de Load Balancer FALLIDA" -Level "ERROR"
        }
        
        return $TestResult
    }
    catch {
        Write-TestLog "Error ejecutando prueba de Load Balancer: $($_.Exception.Message)" -Level "ERROR"
        
        return [PSCustomObject]@{
            TestType = "LoadBalancerMigration"
            ResourceGroup = $ResourceGroupName
            Success = $false
            StartTime = Get-Date
            EndTime = Get-Date
            Duration = New-TimeSpan
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Invoke-PublicIPMigrationTest {
    param(
        [string]$ResourceGroupName,
        [hashtable]$TestScripts
    )
    
    Write-TestLog "=== EJECUTANDO PRUEBA DE MIGRACIÓN DE PUBLIC IP ==="
    
    try {
        $ScriptPath = Join-Path $TestScriptPath $TestScripts["PublicIP"]
        $TestParams = @{
            ResourceGroupName = $ResourceGroupName
            Location = $Location
            ResourceType = "VM"
            SkipCleanup = $SkipCleanup
        }
        
        Write-TestLog "Ejecutando: $ScriptPath"
        Write-TestLog "Parámetros: $(($TestParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
        
        $Result = & $ScriptPath @TestParams
        
        $TestResult = [PSCustomObject]@{
            TestType = "PublicIPMigration"
            ResourceGroup = $ResourceGroupName
            Success = $LASTEXITCODE -eq 0
            StartTime = Get-Date
            EndTime = Get-Date
            Duration = (Get-Date) - $StartTime
            ErrorMessage = if ($LASTEXITCODE -ne 0) { "Test failed with exit code $LASTEXITCODE" } else { $null }
        }
        
        if ($TestResult.Success) {
            Write-TestLog "✅ Prueba de Public IP EXITOSA"
        }
        else {
            Write-TestLog "❌ Prueba de Public IP FALLIDA" -Level "ERROR"
        }
        
        return $TestResult
    }
    catch {
        Write-TestLog "Error ejecutando prueba de Public IP: $($_.Exception.Message)" -Level "ERROR"
        
        return [PSCustomObject]@{
            TestType = "PublicIPMigration"
            ResourceGroup = $ResourceGroupName
            Success = $false
            StartTime = Get-Date
            EndTime = Get-Date
            Duration = New-TimeSpan
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Show-TestSummary {
    param([array]$Results)
    
    Write-TestLog ""
    Write-TestLog "===========================================" 
    Write-TestLog "     RESUMEN DE PRUEBAS DE MIGRACIÓN      "
    Write-TestLog "==========================================="
    Write-TestLog ""
    
    $TotalDuration = (Get-Date) - $StartTime
    $SuccessCount = ($Results | Where-Object { $_.Success }).Count
    $FailureCount = ($Results | Where-Object { -not $_.Success }).Count
    
    Write-TestLog "ESTADÍSTICAS GENERALES:"
    Write-TestLog "  Total de pruebas: $($Results.Count)"
    Write-TestLog "  Exitosas: $SuccessCount"
    Write-TestLog "  Fallidas: $FailureCount"
    Write-TestLog "  Duración total: $($TotalDuration.ToString('hh\:mm\:ss'))"
    Write-TestLog ""
    
    Write-TestLog "RESULTADOS DETALLADOS:"
    foreach ($Result in $Results) {
        $Status = if ($Result.Success) { "✅ EXITOSA" } else { "❌ FALLIDA" }
        $Duration = $Result.Duration.ToString('mm\:ss')
        
        Write-TestLog "  $($Result.TestType): $Status (Duración: $Duration)"
        Write-TestLog "    Grupo de recursos: $($Result.ResourceGroup)"
        
        if (-not $Result.Success -and $Result.ErrorMessage) {
            Write-TestLog "    Error: $($Result.ErrorMessage)" -Level "ERROR"
        }
    }
    
    Write-TestLog ""
    Write-TestLog "RECOMENDACIONES POST-PRUEBA:"
    Write-TestLog "1. ✅ Verificar que todos los recursos de prueba fueron eliminados"
    Write-TestLog "2. 📋 Revisar logs detallados para cada prueba individual"
    Write-TestLog "3. 🔍 Validar facturas de Azure para confirmar limpieza completa"
    
    if ($FailureCount -gt 0) {
        Write-TestLog "4. 🔧 Investigar errores en pruebas fallidas antes de usar en producción" -Level "WARNING"
    }
    else {
        Write-TestLog "4. 🎉 Todos los scripts de migración validados - listos para producción"
    }
    
    Write-TestLog ""
    Write-TestLog "==========================================="
}

function Remove-AllTestResources {
    param([hashtable]$ResourceGroups)
    
    if ($SkipCleanup) {
        Write-TestLog "⚠️ Omitiendo limpieza por parámetro -SkipCleanup" -Level "WARNING"
        Write-TestLog "RECURSOS QUE PERMANECEN ACTIVOS:" -Level "WARNING"
        foreach ($RG in $ResourceGroups.Values) {
            Write-TestLog "  - $RG" -Level "WARNING"
        }
        return
    }
    
    Write-TestLog "=== LIMPIEZA FINAL DE RECURSOS ==="
    
    foreach ($RGName in $ResourceGroups.Values) {
        try {
            $RG = Get-AzResourceGroup -Name $RGName -ErrorAction SilentlyContinue
            if ($RG) {
                Write-TestLog "Eliminando grupo de recursos: $RGName"
                Remove-AzResourceGroup -Name $RGName -Force -AsJob
                Write-TestLog "✓ Eliminación iniciada para: $RGName"
            }
        }
        catch {
            Write-TestLog "Error eliminando $RGName : $($_.Exception.Message)" -Level "ERROR"
        }
    }
    
    # Esperar a que se completen las eliminaciones
    Write-TestLog "Esperando completar eliminaciones..."
    $Jobs = Get-Job | Where-Object { $_.Command -like "*Remove-AzResourceGroup*" }
    if ($Jobs) {
        $Jobs | Wait-Job -Timeout 300  # 5 minutos máximo
        $Jobs | Remove-Job
    }
    
    Write-TestLog "✓ Limpieza final completada"
}

# Ejecución principal
try {
    Write-TestLog "==============================================="
    Write-TestLog "  INICIANDO SUITE DE PRUEBAS DE MIGRACIÓN   "
    Write-TestLog "==============================================="
    Write-TestLog ""
    Write-TestLog "Configuración:"
    Write-TestLog "  Ubicación: $Location"
    Write-TestLog "  Prefijo: $TestPrefix"
    Write-TestLog "  Ejecución paralela: $ParallelExecution"
    Write-TestLog "  Omitir limpieza: $SkipCleanup"
    Write-TestLog ""
    
    # Prerequisitos
    $TestScripts = Test-Prerequisites
    $ResourceGroups = New-TestResourceGroups
    
    # Confirmar ejecución
    if (-not $WhatIf) {
        Write-TestLog "⚠️ ADVERTENCIA: Esta suite creará recursos en Azure que generarán costos"
        Write-TestLog "Grupos de recursos a crear: $($ResourceGroups.Values -join ', ')"
        Write-TestLog ""
        
        $Confirmation = Read-Host "¿Desea continuar con la ejecución de todas las pruebas? (s/N)"
        if ($Confirmation -notmatch "^[SsYy]$") {
            Write-TestLog "Suite de pruebas cancelada por el usuario"
            exit 0
        }
    }
    
    # Ejecutar pruebas en orden
    if (-not $SkipDiskTest) {
        $DiskResult = Invoke-DiskMigrationTest -ResourceGroupName $ResourceGroups["Disk"] -TestScripts $TestScripts
        $TestResults += $DiskResult
        
        if (-not $DiskResult.Success -and -not $ParallelExecution) {
            Write-TestLog "⚠️ Prueba de discos falló - continuando con siguiente prueba" -Level "WARNING"
        }
    }
    
    if (-not $SkipLoadBalancerTest) {
        $LBResult = Invoke-LoadBalancerMigrationTest -ResourceGroupName $ResourceGroups["LoadBalancer"] -TestScripts $TestScripts
        $TestResults += $LBResult
        
        if (-not $LBResult.Success -and -not $ParallelExecution) {
            Write-TestLog "⚠️ Prueba de Load Balancer falló - continuando con siguiente prueba" -Level "WARNING"
        }
    }
    
    if (-not $SkipPublicIPTest) {
        $PIPResult = Invoke-PublicIPMigrationTest -ResourceGroupName $ResourceGroups["PublicIP"] -TestScripts $TestScripts
        $TestResults += $PIPResult
    }
    
    # Mostrar resumen final
    Show-TestSummary -Results $TestResults
    
    # Limpieza final
    Remove-AllTestResources -ResourceGroups $ResourceGroups
    
    # Determinar código de salida
    $FailedTests = $TestResults | Where-Object { -not $_.Success }
    if ($FailedTests.Count -gt 0) {
        Write-TestLog "Suite completada con $($FailedTests.Count) pruebas fallidas" -Level "WARNING"
        exit 1
    }
    else {
        Write-TestLog "🎉 SUITE DE PRUEBAS COMPLETADA EXITOSAMENTE 🎉"
        exit 0
    }
}
catch {
    Write-TestLog "Suite de pruebas falló con error crítico: $($_.Exception.Message)" -Level "ERROR"
    Write-TestLog ""
    Write-TestLog "POSIBLES RECURSOS HUÉRFANOS:"
    if ($ResourceGroups) {
        foreach ($RG in $ResourceGroups.Values) {
            Write-TestLog "  - Grupo de recursos: $RG"
        }
    }
    Write-TestLog ""
    Write-TestLog "Ejecute manualmente la limpieza si es necesario:"
    Write-TestLog "Remove-AzResourceGroup -Name [nombre-grupo] -Force"
    exit 1
}
