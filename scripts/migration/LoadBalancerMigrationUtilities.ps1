#Requires -Version 5.1
#Requires -Modules Az.Network, Az.Resources

<#
.SYNOPSIS
    Utilidades para la migración de Load Balancers básicos a Standard.

.DESCRIPTION
    Este script proporciona funciones de utilidad para soportar el proceso de migración:
    - Descubrir Load Balancers básicos en el entorno
    - Generar reportes de preparación para migración
    - Validar configuraciones post-migración
    - Limpiar recursos relacionados

.NOTES
    Autor: Equipo de Migración Azure
    Versión: 1.0
#>

function Get-BasicLoadBalancerReport {
    <#
    .SYNOPSIS
        Genera un reporte completo de Load Balancers básicos en el entorno.
    
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
    
    Write-Host "Generando reporte de Load Balancers básicos..." -ForegroundColor Cyan
    
    # Obtener Load Balancers según el alcance
    if ($ResourceGroupName) {
        $LoadBalancers = Get-AzLoadBalancer -ResourceGroupName $ResourceGroupName | Where-Object { $_.Sku.Name -eq "Basic" }
        Write-Host "Analizando $($LoadBalancers.Count) Load Balancers básicos en grupo de recursos: $ResourceGroupName"
    }
    else {
        $AllLBs = Get-AzLoadBalancer
        $LoadBalancers = $AllLBs | Where-Object { $_.Sku.Name -eq "Basic" }
        Write-Host "Analizando $($LoadBalancers.Count) Load Balancers básicos de $($AllLBs.Count) Load Balancers totales en la suscripción"
    }
    
    $Report = @()
    
    foreach ($LB in $LoadBalancers) {
        Write-Host "Analizando Load Balancer: $($LB.Name)" -ForegroundColor Yellow
        
        # Determinar tipo de Load Balancer
        $LBType = if ($LB.FrontendIpConfigurations[0].PublicIpAddress) { "Público" } else { "Interno" }
        
        # Analizar backend pools
        $BackendVMs = @()
        $BackendVMSS = @()
        $HasAKSIndicators = $false
        
        foreach ($BackendPool in $LB.BackendAddressPools) {
            if ($BackendPool.Name -like "*kubernetes*" -or $BackendPool.Name -like "*aks*") {
                $HasAKSIndicators = $true
            }
            
            # Analizar miembros del backend pool
            foreach ($BackendIP in $BackendPool.BackendIpConfigurations) {
                if ($BackendIP.Id -like "*virtualMachines*") {
                    $VMName = ($BackendIP.Id -split "/")[-3]
                    if ($VMName -notin $BackendVMs) {
                        $BackendVMs += $VMName
                    }
                }
                elseif ($BackendIP.Id -like "*virtualMachineScaleSets*") {
                    $VMSSName = ($BackendIP.Id -split "/")[-5]
                    if ($VMSSName -notin $BackendVMSS) {
                        $BackendVMSS += $VMSSName
                    }
                }
            }
        }
        
        # Verificar configuraciones IPv6
        $HasIPv6 = $LB.FrontendIpConfigurations | Where-Object { $_.PrivateIpAddressVersion -eq "IPv6" }
        
        # Verificar Floating IP
        $HasFloatingIP = $LB.LoadBalancingRules | Where-Object { $_.EnableFloatingIP }
        
        # Calcular puntuación de complejidad de migración
        $ComplexityScore = 0
        $ComplexityFactors = @()
        
        if ($LB.FrontendIpConfigurations.Count -gt 1) {
            $ComplexityScore += 2
            $ComplexityFactors += "Múltiples frontends"
        }
        
        if ($LB.BackendAddressPools.Count -gt 2) {
            $ComplexityScore += 2
            $ComplexityFactors += "Múltiples backend pools"
        }
        
        if ($BackendVMSS.Count -gt 0) {
            $ComplexityScore += 3
            $ComplexityFactors += "VMSS backend"
        }
        
        if ($HasFloatingIP) {
            $ComplexityScore += 4
            $ComplexityFactors += "Floating IP habilitado"
        }
        
        if ($LBType -eq "Interno") {
            $ComplexityScore += 2
            $ComplexityFactors += "Load Balancer interno (requiere conectividad saliente)"
        }
        
        # Determinar estado de migración
        $MigrationStatus = "Listo"
        $BlockingIssues = @()
        
        if ($HasIPv6) {
            $MigrationStatus = "Bloqueado"
            $BlockingIssues += "Configuraciones IPv6"
        }
        
        if ($HasAKSIndicators) {
            $MigrationStatus = "Bloqueado"
            $BlockingIssues += "Posible AKS Load Balancer"
        }
        
        if ($ComplexityScore -gt 8) {
            $MigrationStatus = "Revisión Manual"
        }
        
        # Estimar tiempo de inactividad
        $DowntimeEstimate = "2-5 minutos"
        if ($BackendVMSS.Count -gt 0) {
            $DowntimeEstimate = "5-15 minutos"
        }
        if ($ComplexityScore -gt 8) {
            $DowntimeEstimate = "15-60 minutos"
        }
        
        $LBInfo = [PSCustomObject]@{
            LoadBalancerName = $LB.Name
            ResourceGroup = $LB.ResourceGroupName
            Location = $LB.Location
            Type = $LBType
            SKU = $LB.Sku.Name
            FrontendConfigs = $LB.FrontendIpConfigurations.Count
            BackendPools = $LB.BackendAddressPools.Count
            LoadBalancingRules = $LB.LoadBalancingRules.Count
            HealthProbes = $LB.Probes.Count
            InboundNATRules = $LB.InboundNatRules.Count
            InboundNATPools = $LB.InboundNatPools.Count
            BackendVMs = ($BackendVMs -join ", ")
            BackendVMSS = ($BackendVMSS -join ", ")
            HasIPv6 = [bool]$HasIPv6
            HasFloatingIP = [bool]$HasFloatingIP
            HasAKSIndicators = $HasAKSIndicators
            ComplexityScore = $ComplexityScore
            ComplexityFactors = ($ComplexityFactors -join "; ")
            MigrationStatus = $MigrationStatus
            BlockingIssues = ($BlockingIssues -join "; ")
            EstimatedDowntime = $DowntimeEstimate
            Tags = ($LB.Tag.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "; "
        }
        
        $Report += $LBInfo
    }
    
    # Estadísticas de resumen
    $ReadyForMigration = $Report | Where-Object { $_.MigrationStatus -eq "Listo" }
    $NeedReview = $Report | Where-Object { $_.MigrationStatus -eq "Revisión Manual" }
    $Blocked = $Report | Where-Object { $_.MigrationStatus -eq "Bloqueado" }
    
    Write-Host "`n=== RESUMEN ===" -ForegroundColor Yellow
    Write-Host "Total Load Balancers básicos: $($Report.Count)"
    Write-Host "Listos para migración: $($ReadyForMigration.Count)" -ForegroundColor Green
    Write-Host "Requieren revisión manual: $($NeedReview.Count)" -ForegroundColor Yellow
    Write-Host "Bloqueados para migración: $($Blocked.Count)" -ForegroundColor Red
    
    if ($Blocked.Count -gt 0) {
        Write-Host "`nLoad Balancers bloqueados:" -ForegroundColor Red
        $Blocked | Format-Table LoadBalancerName, ResourceGroup, BlockingIssues -AutoSize
    }
    
    if ($NeedReview.Count -gt 0) {
        Write-Host "`nLoad Balancers que requieren revisión:" -ForegroundColor Yellow
        $NeedReview | Format-Table LoadBalancerName, ResourceGroup, ComplexityFactors, EstimatedDowntime -AutoSize
    }
    
    # Exportar reporte si se solicita
    if ($ExportPath) {
        $Report | Export-Csv -Path $ExportPath -NoTypeInformation
        Write-Host "Reporte exportado a: $ExportPath" -ForegroundColor Green
    }
    
    return $Report
}

function Test-LoadBalancerMigrationReadiness {
    <#
    .SYNOPSIS
        Prueba si un Load Balancer básico está listo para migración.
    
    .PARAMETER ResourceGroupName
        Grupo de recursos que contiene el Load Balancer.
        
    .PARAMETER LoadBalancerName
        Nombre del Load Balancer básico a probar.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $true)]
        [string]$LoadBalancerName
    )
    
    Write-Host "Probando preparación de migración para Load Balancer: $LoadBalancerName" -ForegroundColor Cyan
    
    try {
        # Obtener Load Balancer
        $LB = Get-AzLoadBalancer -ResourceGroupName $ResourceGroupName -Name $LoadBalancerName -ErrorAction Stop
        
        if ($LB.Sku.Name -ne "Basic") {
            Write-Host "❌ Load Balancer no es de SKU Basic" -ForegroundColor Red
            return $false
        }
        
        $Issues = @()
        $Warnings = @()
        
        # Prueba 1: Verificar configuraciones IPv6
        $IPv6Configs = $LB.FrontendIpConfigurations | Where-Object { $_.PrivateIpAddressVersion -eq "IPv6" }
        if ($IPv6Configs) {
            $Issues += "Configuraciones frontend IPv6 detectadas (no soportadas)"
        }
        else {
            Write-Host "  ✓ No hay configuraciones IPv6" -ForegroundColor Green
        }
        
        # Prueba 2: Verificar indicadores de AKS
        $AKSIndicators = $LB.BackendAddressPools | Where-Object { $_.Name -like "*kubernetes*" -or $_.Name -like "*aks*" }
        if ($AKSIndicators) {
            $Issues += "Posibles indicadores de AKS detectados (no soportado con este script)"
        }
        else {
            Write-Host "  ✓ No se detectaron indicadores de AKS" -ForegroundColor Green
        }
        
        # Prueba 3: Verificar bloqueos de recursos
        try {
            $Locks = Get-AzResourceLock -ResourceGroupName $ResourceGroupName -ResourceName $LoadBalancerName -ResourceType "Microsoft.Network/loadBalancers" 2>$null
            if ($Locks) {
                $Issues += "Bloqueos de recursos detectados en el Load Balancer"
            }
            else {
                Write-Host "  ✓ No hay bloqueos de recursos en el Load Balancer" -ForegroundColor Green
            }
        }
        catch {
            $Warnings += "No se pudo verificar bloqueos de recursos"
        }
        
        # Prueba 4: Verificar backend pools vacíos
        $EmptyPools = $LB.BackendAddressPools | Where-Object { $_.BackendIpConfigurations.Count -eq 0 }
        if ($EmptyPools) {
            $Warnings += "Backend pools vacíos detectados: $($EmptyPools.Name -join ', ')"
        }
        else {
            Write-Host "  ✓ Todos los backend pools tienen miembros" -ForegroundColor Green
        }
        
        # Prueba 5: Verificar reglas de Load Balancing huérfanas
        $OrphanRules = $LB.LoadBalancingRules | Where-Object { -not $_.BackendAddressPool }
        if ($OrphanRules) {
            $Warnings += "Reglas de Load Balancing sin backend pool: $($OrphanRules.Name -join ', ')"
        }
        else {
            Write-Host "  ✓ Todas las reglas tienen backend pools asignados" -ForegroundColor Green
        }
        
        # Prueba 6: Verificar conectividad saliente para Load Balancers internos
        $IsInternal = -not ($LB.FrontendIpConfigurations[0].PublicIpAddress)
        if ($IsInternal) {
            $Warnings += "Load Balancer interno - planificar conectividad saliente para backend pools"
            Write-Host "  ⚠️  Load Balancer interno detectado - revisar conectividad saliente" -ForegroundColor Yellow
        }
        
        # Prueba 7: Verificar Network Security Groups en backend pools
        $BackendNICs = @()
        foreach ($Pool in $LB.BackendAddressPools) {
            foreach ($IPConfig in $Pool.BackendIpConfigurations) {
                $NICId = ($IPConfig.Id -split "/ipConfigurations")[0]
                if ($NICId -notin $BackendNICs) {
                    $BackendNICs += $NICId
                }
            }
        }
        
        $NICsWithoutNSG = 0
        foreach ($NICId in $BackendNICs) {
            try {
                $NIC = Get-AzNetworkInterface -ResourceId $NICId -ErrorAction SilentlyContinue
                if ($NIC -and -not $NIC.NetworkSecurityGroup) {
                    $NICsWithoutNSG++
                }
            }
            catch {
                # Ignorar errores de acceso a NICs
            }
        }
        
        if ($NICsWithoutNSG -gt 0) {
            $Warnings += "$NICsWithoutNSG interfaces de red sin Network Security Group (se crearán automáticamente)"
        }
        
        # Mostrar resultados
        $ReadinessStatus = if ($Issues.Count -eq 0) { "LISTO" } else { "NO LISTO" }
        
        Write-Host "`n=== RESULTADO DE PREPARACIÓN ===" -ForegroundColor Yellow
        Write-Host "Load Balancer: $LoadBalancerName"
        Write-Host "Estado: $ReadinessStatus" -ForegroundColor $(if ($ReadinessStatus -eq "LISTO") { "Green" } else { "Red" })
        
        if ($Issues.Count -gt 0) {
            Write-Host "`nProblemas que bloquean la migración:" -ForegroundColor Red
            foreach ($Issue in $Issues) {
                Write-Host "  ❌ $Issue" -ForegroundColor Red
            }
        }
        
        if ($Warnings.Count -gt 0) {
            Write-Host "`nAdvertencias (no bloquean migración):" -ForegroundColor Yellow
            foreach ($Warning in $Warnings) {
                Write-Host "  ⚠️  $Warning" -ForegroundColor Yellow
            }
        }
        
        return $Issues.Count -eq 0
    }
    catch {
        Write-Host "❌ Error al probar Load Balancer: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Get-LoadBalancerBackendConnectivity {
    <#
    .SYNOPSIS
        Analiza la conectividad saliente de miembros del backend pool.
    
    .PARAMETER ResourceGroupName
        Grupo de recursos que contiene el Load Balancer.
        
    .PARAMETER LoadBalancerName
        Nombre del Load Balancer a analizar.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $true)]
        [string]$LoadBalancerName
    )
    
    Write-Host "Analizando conectividad de backend para Load Balancer: $LoadBalancerName" -ForegroundColor Cyan
    
    try {
        $LB = Get-AzLoadBalancer -ResourceGroupName $ResourceGroupName -Name $LoadBalancerName -ErrorAction Stop
        
        # Determinar tipo de Load Balancer
        $IsPublic = $LB.FrontendIpConfigurations[0].PublicIpAddress -ne $null
        $LBType = if ($IsPublic) { "Público" } else { "Interno" }
        
        Write-Host "Tipo de Load Balancer: $LBType" -ForegroundColor Yellow
        
        $ConnectivityReport = @()
        
        # Analizar cada backend pool
        foreach ($Pool in $LB.BackendAddressPools) {
            Write-Host "`nAnalizando Backend Pool: $($Pool.Name)" -ForegroundColor Yellow
            
            foreach ($IPConfig in $Pool.BackendIpConfigurations) {
                $ResourceType = "Desconocido"
                $ResourceName = "Desconocido"
                $HasPublicIP = $false
                $NSGRules = @()
                
                # Determinar tipo de recurso
                if ($IPConfig.Id -like "*virtualMachines*") {
                    $ResourceType = "VM"
                    $ResourceName = ($IPConfig.Id -split "/")[-3]
                }
                elseif ($IPConfig.Id -like "*virtualMachineScaleSets*") {
                    $ResourceType = "VMSS"
                    $ResourceName = ($IPConfig.Id -split "/")[-5]
                }
                
                # Obtener información de la interfaz de red
                try {
                    $NICId = ($IPConfig.Id -split "/ipConfigurations")[0]
                    $NIC = Get-AzNetworkInterface -ResourceId $NICId -ErrorAction SilentlyContinue
                    
                    if ($NIC) {
                        # Verificar IP pública
                        $HasPublicIP = $NIC.IpConfigurations[0].PublicIpAddress -ne $null
                        
                        # Verificar Network Security Group
                        if ($NIC.NetworkSecurityGroup) {
                            $NSGId = $NIC.NetworkSecurityGroup.Id
                            $NSG = Get-AzNetworkSecurityGroup -ResourceId $NSGId -ErrorAction SilentlyContinue
                            if ($NSG) {
                                $OutboundRules = $NSG.SecurityRules | Where-Object { $_.Direction -eq "Outbound" -and $_.Access -eq "Allow" }
                                $NSGRules = $OutboundRules | ForEach-Object { "$($_.Name) ($($_.DestinationPortRange))" }
                            }
                        }
                    }
                }
                catch {
                    Write-Host "  ⚠️  No se pudo obtener información de NIC para $ResourceName" -ForegroundColor Yellow
                }
                
                # Determinar estado de conectividad saliente
                $OutboundStatus = "Desconocido"
                $OutboundMethod = @()
                
                if ($HasPublicIP) {
                    $OutboundStatus = "Disponible"
                    $OutboundMethod += "IP Pública Direct"
                }
                
                if ($IsPublic -and -not $HasPublicIP) {
                    $OutboundStatus = "Disponible via Load Balancer"
                    $OutboundMethod += "SNAT via Load Balancer Público"
                }
                
                if (-not $IsPublic -and -not $HasPublicIP) {
                    $OutboundStatus = "Requiere Configuración"
                    $OutboundMethod += "Necesita NAT Gateway, NVA, o Load Balancer Secundario"
                }
                
                $ConnectivityInfo = [PSCustomObject]@{
                    BackendPool = $Pool.Name
                    ResourceType = $ResourceType
                    ResourceName = $ResourceName
                    HasPublicIP = $HasPublicIP
                    OutboundStatus = $OutboundStatus
                    OutboundMethod = ($OutboundMethod -join "; ")
                    NSGRules = ($NSGRules -join "; ")
                }
                
                $ConnectivityReport += $ConnectivityInfo
            }
        }
        
        # Mostrar resumen
        Write-Host "`n=== RESUMEN DE CONECTIVIDAD ===" -ForegroundColor Yellow
        
        $NeedConfiguration = $ConnectivityReport | Where-Object { $_.OutboundStatus -eq "Requiere Configuración" }
        
        if ($NeedConfiguration.Count -gt 0) {
            Write-Host "⚠️  Recursos que requieren configuración de conectividad saliente:" -ForegroundColor Red
            $NeedConfiguration | Format-Table ResourceName, ResourceType, OutboundMethod -AutoSize
            
            Write-Host "`nOpciones recomendadas para Load Balancer interno:" -ForegroundColor Cyan
            Write-Host "1. NAT Gateway (recomendado después de migrar todos los recursos básicos)"
            Write-Host "2. Network Virtual Appliance (Azure Firewall)"
            Write-Host "3. Load Balancer externo secundario para tráfico saliente"
            Write-Host "4. IPs públicas en recursos (no recomendado)"
        }
        else {
            Write-Host "✓ Todos los recursos backend tienen conectividad saliente configurada" -ForegroundColor Green
        }
        
        return $ConnectivityReport
    }
    catch {
        Write-Host "❌ Error al analizar conectividad: $($_.Exception.Message)" -ForegroundColor Red
        return @()
    }
}

function New-OutboundConnectivityPlan {
    <#
    .SYNOPSIS
        Genera un plan de conectividad saliente para Load Balancers internos después de migración.
    
    .PARAMETER ResourceGroupName
        Grupo de recursos que contiene el Load Balancer.
        
    .PARAMETER LoadBalancerName
        Nombre del Load Balancer interno.
        
    .PARAMETER PreferredSolution
        Solución preferida: 'NATGateway', 'SecondaryLB', 'NVA', 'PublicIPs'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $true)]
        [string]$LoadBalancerName,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('NATGateway', 'SecondaryLB', 'NVA', 'PublicIPs')]
        [string]$PreferredSolution = 'NATGateway'
    )
    
    Write-Host "Generando plan de conectividad saliente para: $LoadBalancerName" -ForegroundColor Cyan
    Write-Host "Solución preferida: $PreferredSolution" -ForegroundColor Yellow
    
    try {
        $LB = Get-AzLoadBalancer -ResourceGroupName $ResourceGroupName -Name $LoadBalancerName -ErrorAction Stop
        
        # Obtener información de subredes
        $Subnets = @()
        foreach ($Pool in $LB.BackendAddressPools) {
            foreach ($IPConfig in $Pool.BackendIpConfigurations) {
                try {
                    $NICId = ($IPConfig.Id -split "/ipConfigurations")[0]
                    $NIC = Get-AzNetworkInterface -ResourceId $NICId -ErrorAction SilentlyContinue
                    if ($NIC -and $NIC.IpConfigurations[0].Subnet) {
                        $SubnetId = $NIC.IpConfigurations[0].Subnet.Id
                        if ($SubnetId -notin $Subnets) {
                            $Subnets += $SubnetId
                        }
                    }
                }
                catch {
                    # Ignorar errores
                }
            }
        }
        
        Write-Host "`n=== PLAN DE CONECTIVIDAD SALIENTE ===" -ForegroundColor Yellow
        Write-Host "Load Balancer interno: $LoadBalancerName"
        Write-Host "Subredes afectadas: $($Subnets.Count)"
        
        switch ($PreferredSolution) {
            'NATGateway' {
                Write-Host "`n📋 PLAN: NAT GATEWAY (RECOMENDADO)" -ForegroundColor Green
                Write-Host ""
                Write-Host "Pasos para implementar:"
                Write-Host "1. Migrar TODOS los Load Balancers básicos primero"
                Write-Host "2. Migrar TODAS las IPs públicas básicas primero"
                Write-Host "3. Crear NAT Gateway:"
                Write-Host "   New-AzNatGateway -ResourceGroupName '$ResourceGroupName' -Name 'nat-gateway-$($LoadBalancerName.ToLower())' -Location '[LOCATION]'"
                Write-Host "4. Asociar NAT Gateway a subredes:"
                foreach ($SubnetId in $Subnets) {
                    $SubnetName = ($SubnetId -split "/")[-1]
                    $VNetName = ($SubnetId -split "/")[-3]
                    Write-Host "   Set-AzVirtualNetworkSubnetConfig -VirtualNetwork `$vnet -Name '$SubnetName' -AddressPrefix '[PREFIX]' -NatGateway `$natGateway"
                }
                Write-Host ""
                Write-Host "Ventajas:"
                Write-Host "- Solución nativa de Azure para conectividad saliente"
                Write-Host "- Alto rendimiento y escalabilidad"
                Write-Host "- IPs salientes predecibles"
                Write-Host "- Sin configuración adicional en VMs"
                Write-Host ""
                Write-Host "Consideraciones:"
                Write-Host "- Requiere que todos los recursos básicos sean migrados primero"
                Write-Host "- Costo adicional por NAT Gateway"
                Write-Host "- Una configuración por subred"
            }
            
            'SecondaryLB' {
                Write-Host "`n📋 PLAN: LOAD BALANCER SECUNDARIO" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "Pasos para implementar:"
                Write-Host "1. Crear Load Balancer público secundario para tráfico saliente"
                Write-Host "2. Agregar recursos backend al Load Balancer secundario"
                Write-Host "3. Configurar reglas de salida en Load Balancer secundario"
                Write-Host "4. NO configurar reglas de entrada en Load Balancer secundario"
                Write-Host ""
                Write-Host "Ejemplo de configuración:"
                Write-Host "`$outboundLB = New-AzLoadBalancer -ResourceGroupName '$ResourceGroupName' -Name 'lb-outbound-$($LoadBalancerName.ToLower())' -Location '[LOCATION]' -Sku Standard"
                Write-Host "Add-AzLoadBalancerOutboundRuleConfig -Name 'OutboundRule' -LoadBalancer `$outboundLB ..."
                Write-Host ""
                Write-Host "Ventajas:"
                Write-Host "- Puede implementarse antes de migrar el Load Balancer interno"
                Write-Host "- Control granular sobre tráfico saliente"
                Write-Host "- Separación de tráfico interno y saliente"
                Write-Host ""
                Write-Host "Consideraciones:"
                Write-Host "- Configuración más compleja"
                Write-Host "- Requiere dos Load Balancers"
                Write-Host "- Costo adicional"
            }
            
            'NVA' {
                Write-Host "`n📋 PLAN: NETWORK VIRTUAL APPLIANCE" -ForegroundColor Magenta
                Write-Host ""
                Write-Host "Pasos para implementar:"
                Write-Host "1. Configurar Azure Firewall o NVA de terceros"
                Write-Host "2. Crear tablas de rutas para dirigir tráfico saliente al NVA"
                Write-Host "3. Configurar reglas de firewall para permitir tráfico necesario"
                Write-Host "4. Asociar tablas de rutas a subredes backend"
                Write-Host ""
                Write-Host "Ejemplo con Azure Firewall:"
                Write-Host "New-AzFirewall -ResourceGroupName '$ResourceGroupName' -Name 'fw-$($LoadBalancerName.ToLower())' ..."
                Write-Host "New-AzRouteTable -ResourceGroupName '$ResourceGroupName' -Name 'rt-$($LoadBalancerName.ToLower())' ..."
                Write-Host ""
                Write-Host "Ventajas:"
                Write-Host "- Control total sobre tráfico saliente"
                Write-Host "- Inspección y filtrado de tráfico"
                Write-Host "- Centralización de políticas de seguridad"
                Write-Host ""
                Write-Host "Consideraciones:"
                Write-Host "- Configuración compleja"
                Write-Host "- Costo significativo (especialmente Azure Firewall)"
                Write-Host "- Punto único de falla si no se implementa HA"
            }
            
            'PublicIPs' {
                Write-Host "`n📋 PLAN: IPs PÚBLICAS DIRECTAS (NO RECOMENDADO)" -ForegroundColor Red
                Write-Host ""
                Write-Host "Pasos para implementar:"
                Write-Host "1. Crear IP pública Standard para cada VM/VMSS"
                Write-Host "2. Asociar IPs públicas a interfaces de red"
                Write-Host "3. Actualizar Network Security Groups para restricir acceso"
                Write-Host ""
                Write-Host "⚠️  ADVERTENCIAS:"
                Write-Host "- Aumenta superficie de ataque significativamente"
                Write-Host "- Costo elevado (IP pública por recurso)"
                Write-Host "- Gestión compleja de IPs"
                Write-Host "- No recomendado para producción"
                Write-Host ""
                Write-Host "Solo considerar para:"
                Write-Host "- Entornos de desarrollo/prueba"
                Write-Host "- Recursos que requieren IPs salientes específicas"
                Write-Host "- Soluciones temporales"
            }
        }
        
        Write-Host "`n📊 RESUMEN DE COSTOS ESTIMADOS (mensual):" -ForegroundColor Yellow
        Write-Host "NAT Gateway: ~`$45 USD + `$0.045 por GB procesado"
        Write-Host "Load Balancer Secundario: ~`$18 USD + reglas/datos"
        Write-Host "Azure Firewall: ~`$1,200 USD + `$0.016 por GB procesado"
        Write-Host "IPs Públicas: ~`$3.65 USD por IP por mes"
        Write-Host ""
        Write-Host "💡 RECOMENDACIÓN: Usar NAT Gateway después de completar todas las migraciones básicas"
    }
    catch {
        Write-Host "❌ Error al generar plan: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Exportar funciones para uso en otros scripts
Export-ModuleMember -Function Get-BasicLoadBalancerReport, Test-LoadBalancerMigrationReadiness, Get-LoadBalancerBackendConnectivity, New-OutboundConnectivityPlan
