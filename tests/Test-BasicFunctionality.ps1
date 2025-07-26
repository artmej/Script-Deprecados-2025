# Test básico de funcionalidad de los scripts
Write-Host "=== PRUEBA BÁSICA DE SCRIPTS DE MIGRACIÓN ===" -ForegroundColor Green
Write-Host ""

# Verificar prerequisitos
Write-Host "1. Verificando módulos de Azure..." -ForegroundColor Yellow
$RequiredModules = @('Az.Compute', 'Az.Resources', 'Az.Storage', 'Az.Network')
foreach ($Module in $RequiredModules) {
    $ModuleInfo = Get-Module -ListAvailable -Name $Module | Select-Object -First 1
    if ($ModuleInfo) {
        Write-Host "   ✓ $Module versión $($ModuleInfo.Version)" -ForegroundColor Green
    } else {
        Write-Host "   ❌ $Module NO INSTALADO" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "2. Verificando conexión a Azure..." -ForegroundColor Yellow
$Context = Get-AzContext
if ($Context) {
    Write-Host "   ✓ Conectado como: $($Context.Account.Id)" -ForegroundColor Green
    Write-Host "   ✓ Suscripción: $($Context.Subscription.Name)" -ForegroundColor Green
} else {
    Write-Host "   ❌ NO CONECTADO A AZURE" -ForegroundColor Red
    Write-Host "   Ejecutar: Connect-AzAccount" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "3. Verificando scripts de migración..." -ForegroundColor Yellow
$Scripts = @{
    "Script Maestro" = ".\scripts\migration\Invoke-AzureResourceMigration.ps1"
    "Migración Discos" = ".\scripts\migration\Convert-UnmanagedToManagedDisks.ps1"
    "Migración Load Balancer" = ".\scripts\migration\Convert-BasicToStandardLoadBalancer.ps1"
    "Migración Public IP" = ".\scripts\migration\Convert-BasicToStandardPublicIP.ps1"
    "Utilidades Discos" = ".\scripts\migration\MigrationUtilities.ps1"
    "Test Discos" = ".\tests\Test-DiskMigration.ps1"
}

foreach ($Script in $Scripts.GetEnumerator()) {
    if (Test-Path $Script.Value) {
        Write-Host "   ✓ $($Script.Key)" -ForegroundColor Green
    } else {
        Write-Host "   ❌ $($Script.Key) - No encontrado: $($Script.Value)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "4. Probando carga de utilidades..." -ForegroundColor Yellow
try {
    . .\scripts\migration\MigrationUtilities.ps1
    Write-Host "   ✓ Utilidades de migración cargadas" -ForegroundColor Green
    
    # Probar una función
    if (Get-Command Get-UnmanagedDiskReport -ErrorAction SilentlyContinue) {
        Write-Host "   ✓ Función Get-UnmanagedDiskReport disponible" -ForegroundColor Green
    } else {
        Write-Host "   ⚠️ Funciones no disponibles después de cargar" -ForegroundColor Yellow
    }
} catch {
    Write-Host "   ❌ Error cargando utilidades: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== PRUEBA BÁSICA COMPLETADA ===" -ForegroundColor Green
Write-Host ""
Write-Host "SIGUIENTES PASOS:" -ForegroundColor Cyan
Write-Host "1. Si todos los módulos están ✓, puedes usar los scripts de migración"
Write-Host "2. Para probar: .\tests\Test-DiskMigration.ps1 -ResourceGroupName 'test-rg' -Location 'East US'"
Write-Host "3. Para migrar: .\scripts\migration\Invoke-AzureResourceMigration.ps1 -ResourceId 'tu-resource-id'"
Write-Host ""
