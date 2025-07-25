#Requires -Version 5.1
#Requires -Modules Az.Network, Az.Resources

<#
.SYNOPSIS
    Script de prueba para migración de Load Balancer Basic a Standard.

.DESCRIPTION
    Este script crea recursos de prueba con Load Balancer Basic y luego
    ejecuta el script de migración para probar el proceso completo.
    
    El proceso incluye:
    1. Crear VMs backend y recursos de red
    2. Crear Load Balancer Basic con reglas
    3. Ejecutar script de migración
    4. Validar resultados
    5. Limpiar recursos de prueba

.PARAMETER ResourceGroupName
    Nombre del grupo de recursos para las pruebas.

.PARAMETER LoadBalancerName
    Nombre del Load Balancer de prueba a crear.

.PARAMETER Location
    Ubicación de Azure para crear los recursos.

.PARAMETER SkipCleanup
    No eliminar recursos después de la prueba.

.PARAMETER TestMigrationOnly
    Solo ejecutar la migración, asumiendo que los recursos ya existen.

.PARAMETER LoadBalancerType
    Tipo de Load Balancer a crear: Public o Internal.

.EXAMPLE
    .\Test-LoadBalancerMigration.ps1 -ResourceGroupName "rg-test-lb" -Location "East US"

.NOTES
    Este script es para PRUEBAS ÚNICAMENTE.
    Los recursos creados generarán costos en Azure.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$LoadBalancerName = "lb-test-basic",

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCleanup,

    [Parameter(Mandatory = $false)]
    [switch]$TestMigrationOnly,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Public", "Internal")]
    [string]$LoadBalancerType = "Public"
)

# Variables globales para el test
$VNetName = "vnet-test-lb"
$SubnetName = "subnet-backend"
$PublicIPName = "pip-test-lb"
$NSGName = "nsg-test-lb"
$BackendVMCount = 2
$TestResults = @()

# Función para logging
function Write-TestLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "[$Timestamp] [TEST-LB-$Level] $Message"
    Write-Host $LogMessage
}

function Test-Prerequisites {
    Write-TestLog "Verificando prerequisitos de prueba..."
    
    # Verificar que existe el script de migración
    $MigrationScript = Join-Path (Split-Path $PSScriptRoot -Parent) "scripts\migration\Convert-BasicToStandardLoadBalancer.ps1"
    if (-not (Test-Path $MigrationScript)) {
        throw "Script de migración no encontrado: $MigrationScript"
    }
    
    # Verificar conexión a Azure
    $Context = Get-AzContext
    if (-not $Context) {
        throw "No conectado a Azure. Ejecutar Connect-AzAccount"
    }
    
    Write-TestLog "✓ Prerequisitos verificados"
    return $MigrationScript
}

function New-TestResourceGroup {
    Write-TestLog "Creando grupo de recursos de prueba: $ResourceGroupName"
    
    try {
        $RG = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
        if ($RG) {
            Write-TestLog "Grupo de recursos ya existe: $ResourceGroupName"
        }
        else {
            $RG = New-AzResourceGroup -Name $ResourceGroupName -Location $Location
            Write-TestLog "✓ Grupo de recursos creado: $ResourceGroupName"
        }
        return $RG
    }
    catch {
        Write-TestLog "Error creando grupo de recursos: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function New-TestNetworkResources {
    Write-TestLog "Creando recursos de red de prueba..."
    
    try {
        # Crear NSG con reglas básicas
        $NSGRule1 = New-AzNetworkSecurityRuleConfig `
            -Name "Allow-HTTP" `
            -Description "Allow HTTP" `
            -Access Allow `
            -Protocol Tcp `
            -Direction Inbound `
            -Priority 1000 `
            -SourceAddressPrefix * `
            -SourcePortRange * `
            -DestinationAddressPrefix * `
            -DestinationPortRange 80
        
        $NSGRule2 = New-AzNetworkSecurityRuleConfig `
            -Name "Allow-RDP" `
            -Description "Allow RDP" `
            -Access Allow `
            -Protocol Tcp `
            -Direction Inbound `
            -Priority 1100 `
            -SourceAddressPrefix * `
            -SourcePortRange * `
            -DestinationAddressPrefix * `
            -DestinationPortRange 3389
        
        $NSG = New-AzNetworkSecurityGroup `
            -ResourceGroupName $ResourceGroupName `
            -Location $Location `
            -Name $NSGName `
            -SecurityRules $NSGRule1, $NSGRule2
        
        # Crear VNet y Subnet
        $SubnetConfig = New-AzVirtualNetworkSubnetConfig `
            -Name $SubnetName `
            -AddressPrefix "10.0.1.0/24" `
            -NetworkSecurityGroup $NSG
        
        $VNet = New-AzVirtualNetwork `
            -ResourceGroupName $ResourceGroupName `
            -Location $Location `
            -Name $VNetName `
            -AddressPrefix "10.0.0.0/16" `
            -Subnet $SubnetConfig
        
        # Crear Public IP Basic (para Load Balancer público)
        $PublicIP = $null
        if ($LoadBalancerType -eq "Public") {
            $PublicIP = New-AzPublicIpAddress `
                -ResourceGroupName $ResourceGroupName `
                -Location $Location `
                -Name $PublicIPName `
                -AllocationMethod Dynamic `
                -Sku Basic
        }
        
        Write-TestLog "✓ Recursos de red creados"
        return @{
            VNet = $VNet
            Subnet = $VNet.Subnets[0]
            PublicIP = $PublicIP
            NSG = $NSG
        }
    }
    catch {
        Write-TestLog "Error creando recursos de red: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function New-TestBackendVMs {
    param([object]$NetworkResources)
    
    Write-TestLog "Creando VMs backend para el Load Balancer..."
    
    $BackendVMs = @()
    
    try {
        # Credenciales para las VMs
        $VMUser = "testadmin"
        $VMPassword = ConvertTo-SecureString "Test123456!" -AsPlainText -Force
        $Credential = New-Object System.Management.Automation.PSCredential ($VMUser, $VMPassword)
        
        for ($i = 1; $i -le $BackendVMCount; $i++) {
            $VMName = "vm-backend-$i"
            $NICName = "nic-backend-$i"
            
            Write-TestLog "Creando VM backend $i de $BackendVMCount : $VMName"
            
            # Crear NIC para la VM
            $NIC = New-AzNetworkInterface `
                -ResourceGroupName $ResourceGroupName `
                -Location $Location `
                -Name $NICName `
                -SubnetId $NetworkResources.Subnet.Id
            
            # Configuración de la VM
            $VMConfig = New-AzVMConfig -VMName $VMName -VMSize "Standard_B1s"
            
            # Configurar SO (Windows Server 2019)
            $VMConfig = Set-AzVMOperatingSystem `
                -VM $VMConfig `
                -Windows `
                -ComputerName $VMName `
                -Credential $Credential `
                -ProvisionVMAgent `
                -EnableAutoUpdate
            
            # Configurar imagen
            $VMConfig = Set-AzVMSourceImage `
                -VM $VMConfig `
                -PublisherName "MicrosoftWindowsServer" `
                -Offer "WindowsServer" `
                -Skus "2019-Datacenter-smalldisk" `
                -Version "latest"
            
            # Configurar network interface
            $VMConfig = Add-AzVMNetworkInterface -VM $VMConfig -Id $NIC.Id
            
            # Crear la VM
            $VM = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $VMConfig
            
            $BackendVMs += @{
                VM = $VM
                NIC = $NIC
                Name = $VMName
            }
            
            Write-TestLog "✓ VM backend creada: $VMName"
        }
        
        Write-TestLog "✓ Todas las VMs backend creadas ($BackendVMCount VMs)"
        return $BackendVMs
    }
    catch {
        Write-TestLog "Error creando VMs backend: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function New-TestBasicLoadBalancer {
    param(
        [object]$NetworkResources,
        [array]$BackendVMs
    )
    
    Write-TestLog "Creando Load Balancer Basic: $LoadBalancerName"
    
    try {
        # Crear Frontend IP Configuration
        if ($LoadBalancerType -eq "Public") {
            $FrontendIP = New-AzLoadBalancerFrontendIpConfig `
                -Name "frontend-config" `
                -PublicIpAddress $NetworkResources.PublicIP
        }
        else {
            $FrontendIP = New-AzLoadBalancerFrontendIpConfig `
                -Name "frontend-config" `
                -Subnet $NetworkResources.Subnet `
                -PrivateIpAddress "10.0.1.10"
        }
        
        # Crear Backend Address Pool
        $BackendPool = New-AzLoadBalancerBackendAddressPoolConfig -Name "backend-pool"
        
        # Crear Health Probe
        $HealthProbe = New-AzLoadBalancerProbeConfig `
            -Name "http-probe" `
            -Protocol Http `
            -Port 80 `
            -RequestPath "/" `
            -IntervalInSeconds 15 `
            -ProbeCount 2
        
        # Crear Load Balancing Rule
        $LBRule = New-AzLoadBalancerRuleConfig `
            -Name "http-rule" `
            -FrontendIpConfiguration $FrontendIP `
            -BackendAddressPool $BackendPool `
            -Probe $HealthProbe `
            -Protocol Tcp `
            -FrontendPort 80 `
            -BackendPort 80 `
            -EnableFloatingIP $false `
            -LoadDistribution Default
        
        # Crear NAT Rules para acceso directo a VMs
        $NATRules = @()
        for ($i = 1; $i -le $BackendVMCount; $i++) {
            $NATRule = New-AzLoadBalancerInboundNatRuleConfig `
                -Name "rdp-vm$i" `
                -FrontendIpConfiguration $FrontendIP `
                -Protocol Tcp `
                -FrontendPort (3388 + $i) `
                -BackendPort 3389
            
            $NATRules += $NATRule
        }
        
        # Crear Load Balancer Basic
        $LoadBalancer = New-AzLoadBalancer `
            -ResourceGroupName $ResourceGroupName `
            -Name $LoadBalancerName `
            -Location $Location `
            -Sku Basic `
            -FrontendIpConfiguration $FrontendIP `
            -BackendAddressPool $BackendPool `
            -Probe $HealthProbe `
            -LoadBalancingRule $LBRule `
            -InboundNatRule $NATRules
        
        # Asociar VMs al Backend Pool
        Write-TestLog "Asociando VMs al Backend Pool..."
        
        for ($i = 0; $i -lt $BackendVMs.Count; $i++) {
            $VM = $BackendVMs[$i]
            $NIC = Get-AzNetworkInterface -ResourceId $VM.NIC.Id
            
            # Asociar al backend pool
            $NIC.IpConfigurations[0].LoadBalancerBackendAddressPools = $LoadBalancer.BackendAddressPools[0]
            
            # Asociar NAT rule si existe
            if ($i -lt $NATRules.Count) {
                $NIC.IpConfigurations[0].LoadBalancerInboundNatRules = $LoadBalancer.InboundNatRules[$i]
            }
            
            # Actualizar NIC
            Set-AzNetworkInterface -NetworkInterface $NIC
            
            Write-TestLog "✓ VM $($VM.Name) asociada al Load Balancer"
        }
        
        Write-TestLog "✓ Load Balancer Basic creado: $LoadBalancerName"
        Write-TestLog "  Tipo: $LoadBalancerType"
        Write-TestLog "  Frontend IP: $(if ($LoadBalancerType -eq 'Public') { $NetworkResources.PublicIP.IpAddress } else { '10.0.1.10' })"
        Write-TestLog "  Backend VMs: $BackendVMCount"
        
        return $LoadBalancer
    }
    catch {
        Write-TestLog "Error creando Load Balancer: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Test-BasicLoadBalancerExists {
    Write-TestLog "Verificando que el Load Balancer es Basic SKU..."
    
    try {
        $LB = Get-AzLoadBalancer -ResourceGroupName $ResourceGroupName -Name $LoadBalancerName
        
        if ($LB.Sku.Name -ne "Basic") {
            throw "Load Balancer no es Basic SKU: $($LB.Sku.Name)"
        }
        
        Write-TestLog "✓ Load Balancer confirmado como Basic SKU"
        Write-TestLog "  Nombre: $($LB.Name)"
        Write-TestLog "  SKU: $($LB.Sku.Name)"
        Write-TestLog "  Frontend IPs: $($LB.FrontendIpConfigurations.Count)"
        Write-TestLog "  Backend Pools: $($LB.BackendAddressPools.Count)"
        Write-TestLog "  Reglas: $($LB.LoadBalancingRules.Count)"
        Write-TestLog "  Probes: $($LB.Probes.Count)"
        
        return $true
    }
    catch {
        Write-TestLog "Error verificando Load Balancer: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Invoke-LoadBalancerMigrationScript {
    param([string]$MigrationScriptPath)
    
    Write-TestLog "Ejecutando script de migración de Load Balancer..."
    
    try {
        $MigrationParams = @{
            ResourceGroupName = $ResourceGroupName
            LoadBalancerName = $LoadBalancerName
            WhatIf = $false
            Force = $true
        }
        
        Write-TestLog "Parámetros de migración:"
        $MigrationParams.GetEnumerator() | ForEach-Object {
            Write-TestLog "  $($_.Key): $($_.Value)"
        }
        
        # Ejecutar script de migración
        $Result = & $MigrationScriptPath @MigrationParams
        
        Write-TestLog "✓ Script de migración ejecutado"
        return $Result
    }
    catch {
        Write-TestLog "Error ejecutando migración: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Test-LoadBalancerMigrationResults {
    Write-TestLog "Validando resultados de migración..."
    
    try {
        # Esperar un momento para que se apliquen los cambios
        Start-Sleep -Seconds 30
        
        # Verificar que el Load Balancer ahora es Standard
        $LB = Get-AzLoadBalancer -ResourceGroupName $ResourceGroupName -Name $LoadBalancerName
        
        if ($LB.Sku.Name -ne "Standard") {
            throw "Load Balancer no se migró correctamente - SKU: $($LB.Sku.Name)"
        }
        
        Write-TestLog "✓ Load Balancer migrado exitosamente a Standard SKU"
        
        # Verificar configuraciones mantenidas
        $ConfigsPreserved = @()
        
        if ($LB.FrontendIpConfigurations.Count -gt 0) {
            $ConfigsPreserved += "Frontend IP Configurations"
        }
        
        if ($LB.BackendAddressPools.Count -gt 0) {
            $ConfigsPreserved += "Backend Address Pools"
        }
        
        if ($LB.LoadBalancingRules.Count -gt 0) {
            $ConfigsPreserved += "Load Balancing Rules"
        }
        
        if ($LB.Probes.Count -gt 0) {
            $ConfigsPreserved += "Health Probes"
        }
        
        if ($LB.InboundNatRules.Count -gt 0) {
            $ConfigsPreserved += "NAT Rules"
        }
        
        Write-TestLog "✓ Configuraciones preservadas: $($ConfigsPreserved -join ', ')"
        
        # Verificar Public IP si es público
        if ($LoadBalancerType -eq "Public") {
            $PublicIP = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $PublicIPName
            if ($PublicIP.Sku.Name -eq "Standard") {
                Write-TestLog "✓ Public IP también migrada a Standard"
            }
        }
        
        # Verificar conectividad backend (básica)
        $BackendHealth = @()
        foreach ($Pool in $LB.BackendAddressPools) {
            if ($Pool.BackendIpConfigurations.Count -gt 0) {
                $BackendHealth += "Pool $($Pool.Name): $($Pool.BackendIpConfigurations.Count) miembros"
            }
        }
        
        Write-TestLog "✓ Backend pools: $($BackendHealth -join ', ')"
        
        # Recopilar métricas de la migración
        $TestResult = [PSCustomObject]@{
            TestName = "LoadBalancerMigration"
            LoadBalancerName = $LoadBalancerName
            ResourceGroup = $ResourceGroupName
            LoadBalancerType = $LoadBalancerType
            Success = $true
            OriginalSKU = "Basic"
            NewSKU = $LB.Sku.Name
            FrontendConfigsCount = $LB.FrontendIpConfigurations.Count
            BackendPoolsCount = $LB.BackendAddressPools.Count
            RulesCount = $LB.LoadBalancingRules.Count
            ProbesCount = $LB.Probes.Count
            NATRulesCount = $LB.InboundNatRules.Count
            MigrationTime = Get-Date
            Notes = "Migración exitosa de Load Balancer Basic a Standard"
        }
        
        return $TestResult
    }
    catch {
        Write-TestLog "Error validando migración: $($_.Exception.Message)" -Level "ERROR"
        
        $TestResult = [PSCustomObject]@{
            TestName = "LoadBalancerMigration"
            LoadBalancerName = $LoadBalancerName
            ResourceGroup = $ResourceGroupName
            Success = $false
            Error = $_.Exception.Message
            MigrationTime = Get-Date
        }
        
        return $TestResult
    }
}

function Remove-TestResources {
    if ($SkipCleanup) {
        Write-TestLog "Omitiendo limpieza de recursos por parámetro -SkipCleanup"
        Write-TestLog "RECUERDE: Los recursos de prueba seguirán generando costos"
        return
    }
    
    Write-TestLog "Limpiando recursos de prueba..."
    
    try {
        $Confirmation = Read-Host "¿Desea eliminar todos los recursos de prueba del grupo '$ResourceGroupName'? (s/N)"
        if ($Confirmation -match "^[SsYy]$") {
            Remove-AzResourceGroup -Name $ResourceGroupName -Force
            Write-TestLog "✓ Recursos de prueba eliminados"
        }
        else {
            Write-TestLog "Limpieza cancelada - los recursos permanecen activos"
            Write-TestLog "RECUERDE: Los recursos seguirán generando costos hasta que se eliminen"
        }
    }
    catch {
        Write-TestLog "Error eliminando recursos: $($_.Exception.Message)" -Level "ERROR"
    }
}

# Ejecución principal del test
try {
    Write-TestLog "=== INICIANDO PRUEBA DE MIGRACIÓN DE LOAD BALANCER ==="
    Write-TestLog "Grupo de recursos: $ResourceGroupName"
    Write-TestLog "Load Balancer: $LoadBalancerName"
    Write-TestLog "Tipo: $LoadBalancerType"
    Write-TestLog "Ubicación: $Location"
    Write-TestLog ""
    
    # Prerequisitos
    $MigrationScript = Test-Prerequisites
    
    if (-not $TestMigrationOnly) {
        # Crear recursos de prueba
        Write-TestLog "=== FASE 1: CREACIÓN DE RECURSOS DE PRUEBA ==="
        
        $ResourceGroup = New-TestResourceGroup
        $NetworkResources = New-TestNetworkResources
        
        Write-TestLog "Creando VMs backend (esto puede tomar varios minutos)..."
        $BackendVMs = New-TestBackendVMs -NetworkResources $NetworkResources
        
        $LoadBalancer = New-TestBasicLoadBalancer -NetworkResources $NetworkResources -BackendVMs $BackendVMs
        
        Write-TestLog "✓ Recursos de prueba creados exitosamente"
    }
    
    # Verificar estado inicial
    Write-TestLog ""
    Write-TestLog "=== FASE 2: VERIFICACIÓN DE ESTADO INICIAL ==="
    Test-BasicLoadBalancerExists
    
    # Ejecutar migración
    Write-TestLog ""
    Write-TestLog "=== FASE 3: EJECUCIÓN DE MIGRACIÓN ==="
    $MigrationResult = Invoke-LoadBalancerMigrationScript -MigrationScriptPath $MigrationScript
    
    # Validar resultados
    Write-TestLog ""
    Write-TestLog "=== FASE 4: VALIDACIÓN DE RESULTADOS ==="
    $TestResult = Test-LoadBalancerMigrationResults
    $TestResults += $TestResult
    
    # Mostrar resumen
    Write-TestLog ""
    Write-TestLog "=== RESUMEN DE PRUEBA ==="
    if ($TestResult.Success) {
        Write-TestLog "✅ PRUEBA EXITOSA"
        Write-TestLog "Load Balancer: $($TestResult.LoadBalancerName)"
        Write-TestLog "SKU Original: $($TestResult.OriginalSKU) → Nuevo: $($TestResult.NewSKU)"
        Write-TestLog "Configuraciones: $($TestResult.RulesCount) reglas, $($TestResult.ProbesCount) probes"
        Write-TestLog "Backend: $($TestResult.BackendPoolsCount) pools"
    }
    else {
        Write-TestLog "❌ PRUEBA FALLIDA"
        Write-TestLog "Error: $($TestResult.Error)"
    }
    
    Write-TestLog ""
    Write-TestLog "=== FASE 5: LIMPIEZA ==="
    Remove-TestResources
    
    Write-TestLog ""
    Write-TestLog "=== PRUEBA DE MIGRACIÓN DE LOAD BALANCER COMPLETADA ==="
    
    if (-not $TestResult.Success) {
        exit 1
    }
}
catch {
    Write-TestLog "Prueba falló con error crítico: $($_.Exception.Message)" -Level "ERROR"
    Write-TestLog ""
    Write-TestLog "RECURSOS QUE PUEDEN NECESITAR LIMPIEZA MANUAL:"
    Write-TestLog "- Grupo de recursos: $ResourceGroupName"
    Write-TestLog "- Load Balancer: $LoadBalancerName"
    Write-TestLog "- VMs backend: vm-backend-1, vm-backend-2"
    Write-TestLog ""
    exit 1
}
