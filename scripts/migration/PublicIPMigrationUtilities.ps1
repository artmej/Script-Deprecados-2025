#Requires -Version 5.1
#Requires -Modules Az.Network, Az.Resources, Az.Compute

<#
.SYNOPSIS
    Utilidades para la migración de Public IPs básicas a Standard.

.DESCRIPTION
    Este script proporciona funciones de utilidad para soportar el proceso de migración:
    - Descubrir Public IPs básicas en el entorno
    - Generar reportes de recursos asociados
    - Validar dependencias y prerequisites
    - Análisis de complejidad de migración

.NOTES
    Autor: Equipo de Migración Azure
    Versión: 1.0
#>

function Get-BasicPublicIPReport {
    <#
    .SYNOPSIS
        Genera un reporte completo de Public IPs básicas en el entorno.
    
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
    
    Write-Host "Generando reporte de Public IPs básicas..." -ForegroundColor Cyan
    
    # Obtener Public IPs según el alcance
    if ($ResourceGroupName) {
        $PublicIPs = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName | Where-Object { $_.Sku.Name -eq "Basic" }
        Write-Host "Analizando Public IPs básicas en grupo de recursos: $ResourceGroupName"
    }
    else {
        $AllIPs = Get-AzPublicIpAddress
        $PublicIPs = $AllIPs | Where-Object { $_.Sku.Name -eq "Basic" }
        Write-Host "Analizando $($PublicIPs.Count) Public IPs básicas de $($AllIPs.Count) Public IPs totales en la suscripción"
    }
    
    $Report = @()
    
    foreach ($IP in $PublicIPs) {
        # Determinar recurso asociado
        $AssociatedResource = "No asignada"
        $ResourceType = "Unassigned"
        $ResourceName = ""
        $MigrationComplexity = "Simple"
        $SpecialNotes = ""
        
        if ($IP.IpConfiguration) {
            $ConfigId = $IP.IpConfiguration.Id
            
            if ($ConfigId -match "/virtualMachines/") {
                $ResourceType = "Virtual Machine"
                $ResourceName = ($ConfigId -split "/virtualMachines/")[1].Split("/")[0]
                $AssociatedResource = "VM: $ResourceName"
                $MigrationComplexity = "Simple"
            }
            elseif ($ConfigId -match "/virtualMachineScaleSets/") {
                $ResourceType = "Virtual Machine Scale Set"
                $ResourceName = ($ConfigId -split "/virtualMachineScaleSets/")[1].Split("/")[0]
                $AssociatedResource = "VMSS: $ResourceName"
                $MigrationComplexity = "Complex"
                $SpecialNotes = "Requiere actualización de modelo y rolling upgrade"
            }
            elseif ($ConfigId -match "/loadBalancers/") {
                $ResourceType = "Load Balancer"
                $ResourceName = ($ConfigId -split "/loadBalancers/")[1].Split("/")[0]
                $AssociatedResource = "LB: $ResourceName"
                $MigrationComplexity = "Complex"
                $SpecialNotes = "⚠️ MIGRAR LOAD BALANCER PRIMERO"
            }
            elseif ($ConfigId -match "/virtualNetworkGateways/") {
                $ResourceType = "VPN Gateway"
                $ResourceName = ($ConfigId -split "/virtualNetworkGateways/")[1].Split("/")[0]
                $AssociatedResource = "VPN GW: $ResourceName"
                $MigrationComplexity = "Very Complex"
                $SpecialNotes = "Requiere recreación completa del gateway"
            }
            elseif ($ConfigId -match "/applicationGateways/") {
                $ResourceType = "Application Gateway"
                $ResourceName = ($ConfigId -split "/applicationGateways/")[1].Split("/")[0]
                $AssociatedResource = "App GW: $ResourceName"
                $MigrationComplexity = "Complex"
                $SpecialNotes = "Considerar migración a Application Gateway v2"
            }
        }
        
        # Verificar si está en zona de disponibilidad
        $IsZoneRedundant = $IP.Zones -and $IP.Zones.Count -gt 0
        
        $IPInfo = [PSCustomObject]@{
            PublicIPName = $IP.Name
            ResourceGroup = $IP.ResourceGroupName
            Location = $IP.Location
            IPAddress = $IP.IpAddress
            AllocationMethod = $IP.PublicIpAllocationMethod
            SKU = $IP.Sku.Name
            AssociatedResource = $AssociatedResource
            ResourceType = $ResourceType
            ResourceName = $ResourceName
            MigrationComplexity = $MigrationComplexity
            IsZoneRedundant = $IsZoneRedundant
            CurrentZones = ($IP.Zones -join ", ")
            DnsSettings = if ($IP.DnsSettings.DomainNameLabel) { $IP.DnsSettings.DomainNameLabel } else { "No configurado" }
            IdleTimeoutMinutes = $IP.IdleTimeoutInMinutes
            SpecialNotes = $SpecialNotes
            NeedsMigration = $true
        }
        
        $Report += $IPInfo
    }
    
    # Estadísticas de resumen
    $TotalIPs = $Report.Count
    $SimpleCount = ($Report | Where-Object { $_.MigrationComplexity -eq "Simple" }).Count
    $ComplexCount = ($Report | Where-Object { $_.MigrationComplexity -eq "Complex" }).Count
    $VeryComplexCount = ($Report | Where-Object { $_.MigrationComplexity -eq "Very Complex" }).Count
    $UnassignedCount = ($Report | Where-Object { $_.ResourceType -eq "Unassigned" }).Count
    
    Write-Host "`n=== RESUMEN ===" -ForegroundColor Yellow
    Write-Host "Total Public IPs básicas: $TotalIPs"
    Write-Host "Migraciones simples: $SimpleCount" -ForegroundColor Green
    Write-Host "Migraciones complejas: $ComplexCount" -ForegroundColor Yellow
    Write-Host "Migraciones muy complejas: $VeryComplexCount" -ForegroundColor Red
    Write-Host "IPs no asignadas: $UnassignedCount" -ForegroundColor Gray
    
    if ($TotalIPs -gt 0) {
        Write-Host "`nDetalles por tipo de recurso:" -ForegroundColor Cyan
        $Report | Group-Object ResourceType | ForEach-Object {
            Write-Host "  $($_.Name): $($_.Count) IPs"
        }
        
        # Mostrar casos que requieren atención especial
        $SpecialCases = $Report | Where-Object { $_.SpecialNotes -ne "" }
        if ($SpecialCases.Count -gt 0) {
            Write-Host "`n⚠️ CASOS QUE REQUIEREN ATENCIÓN ESPECIAL:" -ForegroundColor Red
            $SpecialCases | Format-Table PublicIPName, AssociatedResource, SpecialNotes -AutoSize
        }
    }
    
    # Exportar reporte si se solicita
    if ($ExportPath) {
        $Report | Export-Csv -Path $ExportPath -NoTypeInformation
        Write-Host "Reporte exportado a: $ExportPath" -ForegroundColor Green
    }
    
    return $Report
}

function Test-PublicIPMigrationReadiness {
    <#
    .SYNOPSIS
        Prueba si el entorno está listo para migración de Public IPs.
    
    .PARAMETER ResourceGroupName
        Grupo de recursos a verificar.
        
    .PARAMETER CheckDependencies
        Incluir verificación detallada de dependencias.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $false)]
        [switch]$CheckDependencies
    )
    
    Write-Host "Verificando preparación para migración de Public IPs..." -ForegroundColor Cyan
    
    $Issues = @()
    $Warnings = @()
    $ReadinessReport = @{
        IsReady = $true
        Issues = @()
        Warnings = @()
        Dependencies = @()
        Recommendations = @()
    }
    
    try {
        # Verificar 1: Load Balancers básicos
        Write-Host "Verificando Load Balancers básicos..." -ForegroundColor Cyan
        $BasicLBs = Get-AzLoadBalancer -ResourceGroupName $ResourceGroupName | Where-Object { $_.Sku.Name -eq "Basic" }
        
        if ($BasicLBs.Count -gt 0) {
            $Issues += "Se encontraron $($BasicLBs.Count) Load Balancers básicos que deben migrarse primero"
            $ReadinessReport.Dependencies += @{
                Type = "LoadBalancer"
                Count = $BasicLBs.Count
                Names = $BasicLBs.Name
                Action = "Migrar primero usando Convert-BasicToStandardLoadBalancer.ps1"
            }
            $ReadinessReport.IsReady = $false
        }
        else {
            Write-Host "  ✓ No se encontraron Load Balancers básicos" -ForegroundColor Green
        }
        
        # Verificar 2: Public IPs básicas
        Write-Host "Analizando Public IPs básicas..." -ForegroundColor Cyan
        $BasicIPs = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName | Where-Object { $_.Sku.Name -eq "Basic" }
        
        if ($BasicIPs.Count -eq 0) {
            Write-Host "  ✓ No se encontraron Public IPs básicas - migración ya completa" -ForegroundColor Green
            return $ReadinessReport
        }
        
        Write-Host "  Se encontraron $($BasicIPs.Count) Public IPs básicas para migrar"
        
        # Verificar 3: Recursos críticos
        Write-Host "Verificando recursos críticos..." -ForegroundColor Cyan
        foreach ($IP in $BasicIPs) {
            if ($IP.IpConfiguration) {
                $ConfigId = $IP.IpConfiguration.Id
                
                # VPN Gateways - muy críticos
                if ($ConfigId -match "/virtualNetworkGateways/") {
                    $GWName = ($ConfigId -split "/virtualNetworkGateways/")[1].Split("/")[0]
                    $Warnings += "VPN Gateway '$GWName' usa Public IP básica - migración causará tiempo de inactividad significativo"
                    $ReadinessReport.Recommendations += "Planificar ventana de mantenimiento para VPN Gateway '$GWName'"
                }
                
                # Application Gateways v1
                if ($ConfigId -match "/applicationGateways/") {
                    $AGWName = ($ConfigId -split "/applicationGateways/")[1].Split("/")[0]
                    try {
                        $AGW = Get-AzApplicationGateway -ResourceGroupName $ResourceGroupName -Name $AGWName
                        if ($AGW.Sku.Name -like "*v1*" -or $AGW.Sku.Tier -eq "Standard") {
                            $Warnings += "Application Gateway '$AGWName' es v1 - considerar migración a v2"
                            $ReadinessReport.Recommendations += "Considerar migrar Application Gateway '$AGWName' a v2 SKU"
                        }
                    }
                    catch {
                        $Warnings += "No se pudo verificar versión de Application Gateway '$AGWName'"
                    }
                }
            }
        }
        
        # Verificar 4: Permisos requeridos si se especifica
        if ($CheckDependencies) {
            Write-Host "Verificando permisos..." -ForegroundColor Cyan
            
            $RequiredActions = @(
                "Microsoft.Network/publicIPAddresses/write",
                "Microsoft.Network/publicIPAddresses/delete",
                "Microsoft.Compute/virtualMachines/write",
                "Microsoft.Network/networkInterfaces/write"
            )
            
            # Esta es una verificación básica - en producción requeriría verificación más detallada
            try {
                $Context = Get-AzContext
                if ($Context) {
                    Write-Host "  ✓ Contexto de Azure encontrado" -ForegroundColor Green
                }
                else {
                    $Issues += "No hay contexto de Azure activo"
                    $ReadinessReport.IsReady = $false
                }
            }
            catch {
                $Issues += "Error al verificar contexto de Azure: $($_.Exception.Message)"
                $ReadinessReport.IsReady = $false
            }
        }
        
        # Verificar 5: Zonas de disponibilidad
        Write-Host "Analizando configuración de zonas..." -ForegroundColor Cyan
        $ZoneCapableRegions = @("East US", "East US 2", "West US 2", "West Europe", "North Europe", "Southeast Asia", "Japan East")
        
        $ResourceGroup = Get-AzResourceGroup -Name $ResourceGroupName
        if ($ResourceGroup.Location -in $ZoneCapableRegions) {
            Write-Host "  ✓ Región soporta zonas de disponibilidad - se configurarán IPs zone-redundant" -ForegroundColor Green
            $ReadinessReport.Recommendations += "Las nuevas Public IPs Standard serán zone-redundant para mayor disponibilidad"
        }
        else {
            $Warnings += "Región '$($ResourceGroup.Location)' no soporta zonas de disponibilidad"
        }
        
        # Compilar resultados
        $ReadinessReport.Issues = $Issues
        $ReadinessReport.Warnings = $Warnings
        
        # Mostrar resultados
        Write-Host "`n=== RESULTADO DE PREPARACIÓN ===" -ForegroundColor Yellow
        
        if ($ReadinessReport.IsReady) {
            Write-Host "✓ LISTO PARA MIGRACIÓN" -ForegroundColor Green
        }
        else {
            Write-Host "❌ NO LISTO - Resolver problemas primero" -ForegroundColor Red
        }
        
        if ($Issues.Count -gt 0) {
            Write-Host "`nPROBLEMAS CRÍTICOS:" -ForegroundColor Red
            foreach ($Issue in $Issues) {
                Write-Host "  ❌ $Issue" -ForegroundColor Red
            }
        }
        
        if ($Warnings.Count -gt 0) {
            Write-Host "`nADVERTENCIAS:" -ForegroundColor Yellow
            foreach ($Warning in $Warnings) {
                Write-Host "  ⚠️ $Warning" -ForegroundColor Yellow
            }
        }
        
        if ($ReadinessReport.Recommendations.Count -gt 0) {
            Write-Host "`nRECOMENDACIONES:" -ForegroundColor Cyan
            foreach ($Recommendation in $ReadinessReport.Recommendations) {
                Write-Host "  💡 $Recommendation" -ForegroundColor Cyan
            }
        }
        
        return $ReadinessReport
    }
    catch {
        Write-Host "Error durante verificación de preparación: $($_.Exception.Message)" -Level "ERROR"
        $ReadinessReport.IsReady = $false
        $ReadinessReport.Issues += "Error durante verificación: $($_.Exception.Message)"
        return $ReadinessReport
    }
}

function Get-PublicIPMigrationComplexity {
    <#
    .SYNOPSIS
        Analiza la complejidad de migración para Public IPs específicas.
    
    .PARAMETER ResourceGroupName
        Grupo de recursos a analizar.
        
    .PARAMETER PublicIPNames
        Nombres específicos de Public IPs a analizar.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $false)]
        [string[]]$PublicIPNames
    )
    
    Write-Host "Analizando complejidad de migración..." -ForegroundColor Cyan
    
    if ($PublicIPNames) {
        $PublicIPs = @()
        foreach ($Name in $PublicIPNames) {
            $IP = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
            if ($IP) {
                $PublicIPs += $IP
            }
        }
    }
    else {
        $PublicIPs = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName | Where-Object { $_.Sku.Name -eq "Basic" }
    }
    
    $ComplexityAnalysis = @()
    
    foreach ($IP in $PublicIPs) {
        $Analysis = [PSCustomObject]@{
            PublicIPName = $IP.Name
            CurrentIP = $IP.IpAddress
            AllocationMethod = $IP.PublicIpAllocationMethod
            Complexity = "Simple"
            EstimatedDowntime = "5-10 minutos"
            RiskLevel = "Low"
            RequiredSteps = @()
            Considerations = @()
            AutomationPossible = $true
        }
        
        # Analizar configuración actual
        if ($IP.IpConfiguration) {
            $ConfigId = $IP.IpConfiguration.Id
            
            if ($ConfigId -match "/virtualMachines/") {
                $Analysis.Complexity = "Simple"
                $Analysis.EstimatedDowntime = "5-10 minutos (reinicio VM)"
                $Analysis.RequiredSteps = @(
                    "Detener VM",
                    "Crear nueva Public IP Standard",
                    "Actualizar configuración NIC",
                    "Iniciar VM",
                    "Eliminar IP básica antigua"
                )
                $Analysis.Considerations = @(
                    "La dirección IP puede cambiar",
                    "Actualizar DNS si es necesario",
                    "VM será reiniciada"
                )
            }
            elseif ($ConfigId -match "/virtualMachineScaleSets/") {
                $Analysis.Complexity = "Complex"
                $Analysis.EstimatedDowntime = "30-60 minutos"
                $Analysis.RiskLevel = "Medium"
                $Analysis.AutomationPossible = $false
                $Analysis.RequiredSteps = @(
                    "Crear nueva Public IP Standard",
                    "Actualizar modelo de VMSS",
                    "Realizar rolling upgrade",
                    "Verificar todas las instancias",
                    "Eliminar IP básica antigua"
                )
                $Analysis.Considerations = @(
                    "Requiere actualización manual del modelo",
                    "Rolling upgrade puede tardar",
                    "Verificar conectividad de cada instancia"
                )
            }
            elseif ($ConfigId -match "/loadBalancers/") {
                $Analysis.Complexity = "Very Complex"
                $Analysis.EstimatedDowntime = "Variable"
                $Analysis.RiskLevel = "High"
                $Analysis.AutomationPossible = $false
                $Analysis.RequiredSteps = @(
                    "USAR SCRIPT ESPECÍFICO PARA LOAD BALANCER",
                    "Convert-BasicToStandardLoadBalancer.ps1"
                )
                $Analysis.Considerations = @(
                    "⚠️ NO migrar directamente",
                    "Usar script específico de Load Balancer",
                    "Migración compleja con múltiples dependencias"
                )
            }
            elseif ($ConfigId -match "/virtualNetworkGateways/") {
                $Analysis.Complexity = "Very Complex"
                $Analysis.EstimatedDowntime = "1-4 horas"
                $Analysis.RiskLevel = "High"
                $Analysis.AutomationPossible = $false
                $Analysis.RequiredSteps = @(
                    "Planificar ventana de mantenimiento",
                    "Documentar configuración actual",
                    "Crear nueva Public IP Standard",
                    "Posible recreación de gateway",
                    "Reconfigurar conexiones VPN",
                    "Pruebas extensivas de conectividad"
                )
                $Analysis.Considerations = @(
                    "Interrupción completa de conectividad VPN",
                    "Puede requerir recreación del gateway",
                    "Actualizar configuraciones on-premises",
                    "Coordinar con equipos de red"
                )
            }
            elseif ($ConfigId -match "/applicationGateways/") {
                $Analysis.Complexity = "Complex"
                $Analysis.EstimatedDowntime = "15-30 minutos"
                $Analysis.RiskLevel = "Medium"
                $Analysis.AutomationPossible = $false
                $Analysis.RequiredSteps = @(
                    "Verificar versión de Application Gateway",
                    "Considerar migración a v2 si es v1",
                    "Crear nueva Public IP Standard",
                    "Actualizar configuración AGW",
                    "Verificar reglas y listeners",
                    "Probar conectividad de aplicaciones"
                )
                $Analysis.Considerations = @(
                    "Si es v1, considerar migrar a v2",
                    "Verificar certificados SSL",
                    "Probar todas las rutas de aplicación",
                    "Actualizar DNS si cambia IP"
                )
            }
        }
        else {
            # IP no asignada
            $Analysis.Complexity = "Simple"
            $Analysis.EstimatedDowntime = "2-5 minutos"
            $Analysis.RequiredSteps = @(
                "Crear nueva Public IP Standard",
                "Eliminar IP básica antigua"
            )
            $Analysis.Considerations = @(
                "IP no está en uso actualmente",
                "Verificar si está reservada para uso futuro"
            )
        }
        
        # Consideraciones adicionales basadas en configuración
        if ($IP.PublicIpAllocationMethod -eq "Static") {
            $Analysis.Considerations += "IP básica estática - puede ser difícil de preservar"
        }
        
        if ($IP.DnsSettings.DomainNameLabel) {
            $Analysis.Considerations += "Tiene etiqueta DNS configurada - verificar después de migración"
        }
        
        $ComplexityAnalysis += $Analysis
    }
    
    # Mostrar resumen
    Write-Host "`n=== ANÁLISIS DE COMPLEJIDAD ===" -ForegroundColor Yellow
    
    $SimpleCount = ($ComplexityAnalysis | Where-Object { $_.Complexity -eq "Simple" }).Count
    $ComplexCount = ($ComplexityAnalysis | Where-Object { $_.Complexity -eq "Complex" }).Count
    $VeryComplexCount = ($ComplexityAnalysis | Where-Object { $_.Complexity -eq "Very Complex" }).Count
    
    Write-Host "Migraciones simples: $SimpleCount" -ForegroundColor Green
    Write-Host "Migraciones complejas: $ComplexCount" -ForegroundColor Yellow
    Write-Host "Migraciones muy complejas: $VeryComplexCount" -ForegroundColor Red
    
    # Mostrar detalles por complejidad
    Write-Host "`nDetalles por Public IP:" -ForegroundColor Cyan
    $ComplexityAnalysis | Format-Table PublicIPName, Complexity, EstimatedDowntime, RiskLevel, AutomationPossible -AutoSize
    
    return $ComplexityAnalysis
}

function New-MigrationPlan {
    <#
    .SYNOPSIS
        Crea un plan detallado de migración para Public IPs básicas.
    
    .PARAMETER ResourceGroupName
        Grupo de recursos a incluir en el plan.
        
    .PARAMETER ExportPath
        Ruta para exportar el plan detallado.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $false)]
        [string]$ExportPath
    )
    
    Write-Host "Creando plan de migración detallado..." -ForegroundColor Cyan
    
    # Obtener información base
    $BasicIPs = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName | Where-Object { $_.Sku.Name -eq "Basic" }
    $ComplexityAnalysis = Get-PublicIPMigrationComplexity -ResourceGroupName $ResourceGroupName
    
    # Crear plan de migración
    $MigrationPlan = @{
        CreatedDate = Get-Date
        ResourceGroup = $ResourceGroupName
        TotalPublicIPs = $BasicIPs.Count
        EstimatedTotalTime = 0
        Phases = @()
        Prerequisites = @()
        PostMigrationTasks = @()
        RiskAssessment = @()
    }
    
    # Fase 1: Prerequisites
    $MigrationPlan.Prerequisites = @(
        "Verificar que no hay Load Balancers básicos pendientes de migración",
        "Coordinar ventana de mantenimiento con equipos afectados",
        "Preparar plan de rollback para recursos críticos",
        "Documentar configuraciones actuales de DNS",
        "Notificar a usuarios sobre posibles cambios de IP",
        "Preparar respaldos de configuraciones críticas"
    )
    
    # Organizar por fases según complejidad
    $SimpleIPs = $ComplexityAnalysis | Where-Object { $_.Complexity -eq "Simple" }
    $ComplexIPs = $ComplexityAnalysis | Where-Object { $_.Complexity -eq "Complex" }
    $VeryComplexIPs = $ComplexityAnalysis | Where-Object { $_.Complexity -eq "Very Complex" }
    
    # Fase 2: Migraciones simples (VMs, IPs no asignadas)
    if ($SimpleIPs.Count -gt 0) {
        $Phase1 = @{
            PhaseName = "Fase 1: Migraciones Simples"
            Order = 1
            EstimatedTime = "30-60 minutos"
            Resources = $SimpleIPs
            Description = "Migrar VMs y IPs no asignadas - bajo riesgo"
            Prerequisites = @("Confirmar VMs pueden ser reiniciadas")
            Steps = @(
                "Crear respaldos de configuración",
                "Migrar IPs no asignadas primero",
                "Migrar VMs una por una",
                "Verificar conectividad después de cada migración"
            )
        }
        $MigrationPlan.Phases += $Phase1
        $MigrationPlan.EstimatedTotalTime += 60
    }
    
    # Fase 3: Migraciones complejas (VMSS, Application Gateway)
    if ($ComplexIPs.Count -gt 0) {
        $Phase2 = @{
            PhaseName = "Fase 2: Migraciones Complejas"
            Order = 2
            EstimatedTime = "1-3 horas"
            Resources = $ComplexIPs
            Description = "Migrar VMSS y Application Gateways - riesgo medio"
            Prerequisites = @(
                "Coordinar con equipos de aplicaciones",
                "Preparar planes de rollback específicos",
                "Verificar ventana de mantenimiento ampliada"
            )
            Steps = @(
                "Migrar Application Gateways (considerar v2)",
                "Actualizar modelos de VMSS",
                "Realizar rolling upgrades",
                "Verificación exhaustiva de conectividad"
            )
        }
        $MigrationPlan.Phases += $Phase2
        $MigrationPlan.EstimatedTotalTime += 180
    }
    
    # Fase 4: Migraciones muy complejas (VPN Gateways)
    if ($VeryComplexIPs.Count -gt 0) {
        $Phase3 = @{
            PhaseName = "Fase 3: Migraciones Críticas"
            Order = 3
            EstimatedTime = "2-8 horas"
            Resources = $VeryComplexIPs
            Description = "Migrar VPN Gateways y recursos críticos - alto riesgo"
            Prerequisites = @(
                "Ventana de mantenimiento extendida aprobada",
                "Equipos on-premises coordinados",
                "Plan de rollback completo preparado",
                "Comunicación a todos los usuarios VPN"
            )
            Steps = @(
                "Documentar configuraciones actuales completamente",
                "Ejecutar respaldos completos",
                "Migrar en horario de menor impacto",
                "Verificación completa de todas las conexiones",
                "Monitoreo extendido post-migración"
            )
        }
        $MigrationPlan.Phases += $Phase3
        $MigrationPlan.EstimatedTotalTime += 300
    }
    
    # Tareas post-migración
    $MigrationPlan.PostMigrationTasks = @(
        "Actualizar registros DNS con nuevas direcciones IP",
        "Actualizar documentación de red",
        "Verificar todas las aplicaciones funcionan correctamente",
        "Actualizar configuraciones de monitoreo y alertas",
        "Eliminar respaldos antiguos después de período de retención",
        "Revisar facturación y costos",
        "Documentar lecciones aprendidas"
    )
    
    # Evaluación de riesgos
    $MigrationPlan.RiskAssessment = @(
        @{
            Risk = "Cambio de direcciones IP públicas"
            Impact = "Alto"
            Mitigation = "Actualizar DNS inmediatamente, comunicar cambios"
        },
        @{
            Risk = "Tiempo de inactividad extendido"
            Impact = "Medio"
            Mitigation = "Planificar ventanas de mantenimiento, tener plan de rollback"
        },
        @{
            Risk = "Pérdida de conectividad VPN"
            Impact = "Alto"
            Mitigation = "Coordinar con equipos on-premises, tener conexiones alternativas"
        },
        @{
            Risk = "Configuraciones de aplicación obsoletas"
            Impact = "Medio"
            Mitigation = "Inventariar todas las dependencias antes de migración"
        }
    )
    
    # Mostrar plan
    Write-Host "`n=== PLAN DE MIGRACIÓN GENERADO ===" -ForegroundColor Yellow
    Write-Host "Grupo de recursos: $ResourceGroupName"
    Write-Host "Total Public IPs a migrar: $($MigrationPlan.TotalPublicIPs)"
    Write-Host "Tiempo estimado total: $([math]::Round($MigrationPlan.EstimatedTotalTime / 60, 1)) horas"
    Write-Host "Número de fases: $($MigrationPlan.Phases.Count)"
    
    foreach ($Phase in $MigrationPlan.Phases) {
        Write-Host "`n$($Phase.PhaseName):" -ForegroundColor Cyan
        Write-Host "  Recursos: $($Phase.Resources.Count)"
        Write-Host "  Tiempo estimado: $($Phase.EstimatedTime)"
        Write-Host "  Descripción: $($Phase.Description)"
    }
    
    # Exportar plan si se solicita
    if ($ExportPath) {
        $MigrationPlan | ConvertTo-Json -Depth 10 | Out-File -FilePath $ExportPath -Encoding UTF8
        Write-Host "`nPlan exportado a: $ExportPath" -ForegroundColor Green
    }
    
    return $MigrationPlan
}

# Exportar funciones para uso en otros scripts
Export-ModuleMember -Function Get-BasicPublicIPReport, Test-PublicIPMigrationReadiness, Get-PublicIPMigrationComplexity, New-MigrationPlan
