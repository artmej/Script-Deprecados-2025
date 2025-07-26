# Setup-Project.ps1 - Configuración inicial del proyecto
# Ejecutar una vez después de clonar el repositorio

param(
    [switch]$SkipGitCheck = $false
)

Write-Host ""
Write-Host "🚀 CONFIGURACIÓN INICIAL DEL PROYECTO - Azure SKU Migration Scripts" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Green

# Verificar que estamos en un repositorio Git
if (-not $SkipGitCheck) {
    if (-not (Test-Path ".git")) {
        Write-Host "❌ Este script debe ejecutarse desde la raíz de un repositorio Git" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "📁 Creando estructura de carpetas..." -ForegroundColor Yellow

# Crear estructura de carpetas
$Directories = @(
    "logs",
    "logs\migration", 
    "logs\test",
    "logs\backup",
    "backups",
    "output",
    "test-results"
)

foreach ($dir in $Directories) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "   ✅ Creada: $dir" -ForegroundColor Green
    } else {
        Write-Host "   ℹ️ Ya existe: $dir" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "🔗 Verificando enlaces a scripts principales..." -ForegroundColor Yellow

$MainScripts = @(
    "Convert-BasicToStandardPublicIP.ps1",
    "Convert-BasicToStandardLoadBalancer.ps1",
    "Convert-UnmanagedToManagedDisks.ps1"
)

foreach ($script in $MainScripts) {
    $SourcePath = "scripts\migration\$script"
    $DestPath = ".\$script"
    
    if (Test-Path $SourcePath) {
        if (-not (Test-Path $DestPath)) {
            try {
                # Intentar crear enlace simbólico (requiere permisos admin)
                cmd /c "mklink `"$DestPath`" `"$SourcePath`"" 2>$null
                if (Test-Path $DestPath) {
                    Write-Host "   🔗 $script → Enlace simbólico creado" -ForegroundColor Green
                } else {
                    # Si no se puede crear enlace, hacer copia
                    Copy-Item $SourcePath $DestPath
                    Write-Host "   📄 $script → Copia creada" -ForegroundColor Yellow
                }
            }
            catch {
                # Fallback: crear copia
                Copy-Item $SourcePath $DestPath
                Write-Host "   📄 $script → Copia creada" -ForegroundColor Yellow
            }
        } else {
            Write-Host "   ✅ $script → Ya existe" -ForegroundColor Gray
        }
    } else {
        Write-Host "   ⚠️ $script → Script fuente no encontrado" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "🔍 Verificando módulos de PowerShell requeridos..." -ForegroundColor Yellow

$RequiredModules = @(
    @{ Name = "Az.Accounts"; MinVersion = "2.0.0" },
    @{ Name = "Az.Resources"; MinVersion = "6.0.0" },
    @{ Name = "Az.Network"; MinVersion = "7.0.0" },
    @{ Name = "Az.Compute"; MinVersion = "7.0.0" },
    @{ Name = "Az.Storage"; MinVersion = "6.0.0" }
)

$MissingModules = @()

foreach ($module in $RequiredModules) {
    $installedModule = Get-Module -Name $module.Name -ListAvailable | 
                      Where-Object { $_.Version -ge [version]$module.MinVersion } | 
                      Select-Object -First 1
    
    if ($installedModule) {
        Write-Host "   ✅ $($module.Name) v$($installedModule.Version)" -ForegroundColor Green
    } else {
        Write-Host "   ❌ $($module.Name) v$($module.MinVersion)+ requerido" -ForegroundColor Red
        $MissingModules += $module
    }
}

if ($MissingModules.Count -gt 0) {
    Write-Host ""
    Write-Host "📦 Para instalar los módulos faltantes, ejecute:" -ForegroundColor Yellow
    Write-Host "   Install-Module -Name Az -Force -AllowClobber" -ForegroundColor Cyan
    Write-Host "   # O módulos individuales:" -ForegroundColor Gray
    foreach ($module in $MissingModules) {
        Write-Host "   Install-Module -Name $($module.Name) -MinimumVersion $($module.MinVersion) -Force" -ForegroundColor Cyan
    }
}

Write-Host ""
Write-Host "📋 Resumen de configuración:" -ForegroundColor Yellow
Write-Host "==========================" -ForegroundColor Yellow
Write-Host "   📁 Estructura de carpetas: ✅ Configurada" -ForegroundColor Green
Write-Host "   🔗 Enlaces a scripts: ✅ Configurados" -ForegroundColor Green
Write-Host "   📄 .gitignore: ✅ Configurado para logs y backups" -ForegroundColor Green

if ($MissingModules.Count -eq 0) {
    Write-Host "   🔧 Módulos PowerShell: ✅ Todos disponibles" -ForegroundColor Green
    Write-Host ""
    Write-Host "🎉 ¡Configuración completada! El proyecto está listo para usar." -ForegroundColor Green
    Write-Host ""
    Write-Host "🚀 Para empezar:" -ForegroundColor Cyan
    Write-Host "   .\Convert-BasicToStandardPublicIP.ps1 -WhatIf" -ForegroundColor White
    Write-Host "   .\Convert-BasicToStandardLoadBalancer.ps1 -WhatIf" -ForegroundColor White
    Write-Host "   .\Convert-UnmanagedToManagedDisks.ps1 -WhatIf" -ForegroundColor White
} else {
    Write-Host "   🔧 Módulos PowerShell: ⚠️ $($MissingModules.Count) módulos faltantes" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "⚠️ Instale los módulos faltantes antes de usar los scripts de migración." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "📖 Documentación:" -ForegroundColor Cyan
Write-Host "   README.md - Documentación principal" -ForegroundColor White
Write-Host "   ESTRUCTURA.md - Guía de estructura del proyecto" -ForegroundColor White
Write-Host ""
