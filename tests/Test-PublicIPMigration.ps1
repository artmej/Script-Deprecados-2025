#Requires -Version 5.1
#Requires -Modules Az.Network, Az.Resources, Az.Compute

<#
.SYNOPSIS
    Script de prueba para migración de Public IP Basic a Standard.

.DESCRIPTION
    Este script crea recursos de prueba con Public IPs Basic y luego
    ejecuta el script de migración para probar el proceso completo.
    
    El proceso incluye:
    1. Crear VM con Public IP Basic
    2. Crear recursos adicionales que usen Public IPs
    3. Ejecutar script de migración
    4. Validar resultados
    5. Limpiar recursos de prueba

.PARAMETER ResourceGroupName
    Nombre del grupo de recursos para las pruebas.

.PARAMETER TestVMName
    Nombre de la VM de prueba a crear.

.PARAMETER Location
    Ubicación de Azure para crear los recursos.

.PARAMETER SkipCleanup
    No eliminar recursos después de la prueba.

.PARAMETER TestMigrationOnly
    Solo ejecutar la migración, asumiendo que los recursos ya existen.

.PARAMETER ResourceType
    Tipo de recurso a probar: VM, Multiple (VM + otros recursos).

.EXAMPLE
    .\Test-PublicIPMigration.ps1 -ResourceGroupName "rg-test-pip" -Location "East US"

.NOTES
    Este script es para PRUEBAS ÚNICAMENTE.
    Los recursos creados generarán costos en Azure.
    
    IMPORTANTE: Ejecutar este test después de migrar cualquier Load Balancer Basic.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$TestVMName = "vm-test-publicip",

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCleanup,

    [Parameter(Mandatory = $false)]
    [switch]$TestMigrationOnly,

    [Parameter(Mandatory = $false)]
    [ValidateSet("VM", "Multiple")]
    [string]$ResourceType = "VM"
)

# Variables globales para el test
$VNetName = "vnet-test-pip"
$SubnetName = "subnet-test"
$PublicIPName = "pip-test-basic"
$NSGName = "nsg-test-pip"
$NICName = "nic-test-pip"
$AdditionalPublicIPName = "pip-test-additional"
$TestResults = @()

# Función para logging
function Write-TestLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "[$Timestamp] [TEST-PIP-$Level] $Message"
    Write-Host $LogMessage
}

function Test-Prerequisites {
    Write-TestLog "Verificando prerequisitos de prueba..."
    
    # Verificar que existe el script de migración
    $MigrationScript = Join-Path (Split-Path $PSScriptRoot -Parent) "scripts\migration\Convert-BasicToStandardPublicIP.ps1"
    if (-not (Test-Path $MigrationScript)) {
        throw "Script de migración no encontrado: $MigrationScript"
    }
    
    # Verificar conexión a Azure
    $Context = Get-AzContext
    if (-not $Context) {
        throw "No conectado a Azure. Ejecutar Connect-AzAccount"
    }
    
    # Verificar que no hay Load Balancers Basic en el grupo de recursos
    Write-TestLog "Verificando ausencia de Load Balancers Basic..."
    try {
        $BasicLBs = Get-AzLoadBalancer -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue | 
                   Where-Object { $_.Sku.Name -eq "Basic" }
        
        if ($BasicLBs.Count -gt 0) {
            Write-TestLog "⚠️ ADVERTENCIA: Se encontraron $($BasicLBs.Count) Load Balancers Basic:" -Level "WARNING"
            foreach ($LB in $BasicLBs) {
                Write-TestLog "  - $($LB.Name)" -Level "WARNING"
            }
            Write-TestLog "Recomendación: Migrar Load Balancers Basic primero" -Level "WARNING"
        }
    }
    catch {
        # Ignorar errores si el grupo de recursos no existe aún
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
        # Crear NSG
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
        
        Write-TestLog "✓ Recursos de red creados"
        return @{
            VNet = $VNet
            Subnet = $VNet.Subnets[0]
            NSG = $NSG
        }
    }
    catch {
        Write-TestLog "Error creando recursos de red: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function New-TestBasicPublicIPs {
    Write-TestLog "Creando Public IPs Basic de prueba..."
    
    try {
        $PublicIPs = @()
        
        # Public IP principal para VM
        $PublicIP1 = New-AzPublicIpAddress `
            -ResourceGroupName $ResourceGroupName `
            -Location $Location `
            -Name $PublicIPName `
            -AllocationMethod Dynamic `
            -Sku Basic
        
        $PublicIPs += $PublicIP1
        Write-TestLog "✓ Public IP Basic creada: $PublicIPName"
        
        # Public IP adicional si se requiere test múltiple
        if ($ResourceType -eq "Multiple") {
            $PublicIP2 = New-AzPublicIpAddress `
                -ResourceGroupName $ResourceGroupName `
                -Location $Location `
                -Name $AdditionalPublicIPName `
                -AllocationMethod Static `
                -Sku Basic
            
            $PublicIPs += $PublicIP2
            Write-TestLog "✓ Public IP Basic adicional creada: $AdditionalPublicIPName"
        }
        
        return $PublicIPs
    }
    catch {
        Write-TestLog "Error creando Public IPs: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function New-TestVMWithBasicPublicIP {
    param(
        [object]$NetworkResources,
        [object]$PublicIP
    )
    
    Write-TestLog "Creando VM de prueba con Public IP Basic: $TestVMName"
    
    try {
        # Crear Network Interface con Public IP Basic
        $NIC = New-AzNetworkInterface `
            -ResourceGroupName $ResourceGroupName `
            -Location $Location `
            -Name $NICName `
            -SubnetId $NetworkResources.Subnet.Id `
            -PublicIpAddressId $PublicIP.Id
        
        # Credenciales para la VM
        $VMUser = "testadmin"
        $VMPassword = ConvertTo-SecureString "Test123456!" -AsPlainText -Force
        $Credential = New-Object System.Management.Automation.PSCredential ($VMUser, $VMPassword)
        
        # Configuración de la VM
        $VMConfig = New-AzVMConfig -VMName $TestVMName -VMSize "Standard_B1s"
        
        # Configurar SO (Windows Server 2019)
        $VMConfig = Set-AzVMOperatingSystem `
            -VM $VMConfig `
            -Windows `
            -ComputerName $TestVMName `
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
        Write-TestLog "Creando VM... (esto puede tomar varios minutos)"
        $VM = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $VMConfig
        
        Write-TestLog "✓ VM creada con Public IP Basic: $TestVMName"
        Write-TestLog "  Public IP: $($PublicIP.Name)"
        
        return $VM
    }
    catch {
        Write-TestLog "Error creando VM: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Test-BasicPublicIPsExist {
    Write-TestLog "Verificando que existen Public IPs Basic..."
    
    try {
        $BasicPublicIPs = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName | 
                         Where-Object { $_.Sku.Name -eq "Basic" }
        
        if ($BasicPublicIPs.Count -eq 0) {
            throw "No se encontraron Public IPs Basic para probar"
        }
        
        Write-TestLog "✓ Se encontraron $($BasicPublicIPs.Count) Public IPs Basic:"
        foreach ($PIP in $BasicPublicIPs) {
            Write-TestLog "  - $($PIP.Name): $($PIP.IpAddress) ($($PIP.PublicIpAllocationMethod))"
        }
        
        return $BasicPublicIPs
    }
    catch {
        Write-TestLog "Error verificando Public IPs: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Invoke-PublicIPMigrationScript {
    param([string]$MigrationScriptPath)
    
    Write-TestLog "Ejecutando script de migración de Public IP..."
    
    try {
        $MigrationParams = @{
            ResourceGroupName = $ResourceGroupName
            ResourceType = "VM"
            WhatIf = $false
            Force = $true
            SkipLoadBalancerCheck = $true  # Asumimos que no hay LBs Basic
        }
        
        # Si hay Public IP específica, usar solo esa
        if ($ResourceType -eq "VM") {
            $MigrationParams.PublicIPName = $PublicIPName
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

function Test-PublicIPMigrationResults {
    Write-TestLog "Validando resultados de migración..."
    
    try {
        # Esperar un momento para que se apliquen los cambios
        Start-Sleep -Seconds 30
        
        # Verificar que las Public IPs ahora son Standard
        $AllPublicIPs = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName
        $StandardPIPs = $AllPublicIPs | Where-Object { $_.Sku.Name -eq "Standard" }
        $BasicPIPs = $AllPublicIPs | Where-Object { $_.Sku.Name -eq "Basic" }
        
        Write-TestLog "Public IPs después de migración:"
        Write-TestLog "  Standard: $($StandardPIPs.Count)"
        Write-TestLog "  Basic: $($BasicPIPs.Count)"
        
        # Verificar VM sigue funcional
        $VM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $TestVMName
        $VMStatus = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $TestVMName -Status
        $PowerState = ($VMStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
        
        Write-TestLog "Estado de VM: $PowerState"
        
        # Verificar NIC tiene nueva Public IP
        $NIC = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $NICName
        $CurrentPublicIPId = $NIC.IpConfigurations[0].PublicIpAddress.Id
        
        if ($CurrentPublicIPId) {
            $CurrentPublicIP = Get-AzPublicIpAddress -ResourceId $CurrentPublicIPId
            Write-TestLog "✓ VM usa Public IP: $($CurrentPublicIP.Name) (SKU: $($CurrentPublicIP.Sku.Name))"
            
            if ($CurrentPublicIP.Sku.Name -ne "Standard") {
                throw "VM no está usando Public IP Standard después de migración"
            }
        }
        else {
            throw "VM no tiene Public IP después de migración"
        }
        
        # Contar Public IPs migradas exitosamente
        $MigratedCount = 0
        $FailedCount = 0
        
        # Verificar si el nombre original cambió (indica migración exitosa)
        $OriginalPIP = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $PublicIPName -ErrorAction SilentlyContinue
        if (-not $OriginalPIP -or $OriginalPIP.Sku.Name -eq "Standard") {
            $MigratedCount++
        }
        else {
            $FailedCount++
        }
        
        # Recopilar métricas de la migración
        $TestResult = [PSCustomObject]@{
            TestName = "PublicIPMigration"
            VMName = $TestVMName
            ResourceGroup = $ResourceGroupName
            Success = ($FailedCount -eq 0)
            PublicIPsMigrated = $MigratedCount
            PublicIPsFailed = $FailedCount
            TotalStandardPIPs = $StandardPIPs.Count
            VMPowerState = $PowerState
            NewPublicIPName = $CurrentPublicIP.Name
            NewPublicIPAddress = $CurrentPublicIP.IpAddress
            MigrationTime = Get-Date
            Notes = if ($FailedCount -eq 0) { "Migración exitosa de Public IPs Basic a Standard" } else { "Algunas migraciones fallaron" }
        }
        
        return $TestResult
    }
    catch {
        Write-TestLog "Error validando migración: $($_.Exception.Message)" -Level "ERROR"
        
        $TestResult = [PSCustomObject]@{
            TestName = "PublicIPMigration"
            VMName = $TestVMName
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
    Write-TestLog "=== INICIANDO PRUEBA DE MIGRACIÓN DE PUBLIC IP ==="
    Write-TestLog "Grupo de recursos: $ResourceGroupName"
    Write-TestLog "VM de prueba: $TestVMName"
    Write-TestLog "Tipo de recurso: $ResourceType"
    Write-TestLog "Ubicación: $Location"
    Write-TestLog ""
    
    # Prerequisitos
    $MigrationScript = Test-Prerequisites
    
    if (-not $TestMigrationOnly) {
        # Crear recursos de prueba
        Write-TestLog "=== FASE 1: CREACIÓN DE RECURSOS DE PRUEBA ==="
        
        $ResourceGroup = New-TestResourceGroup
        $NetworkResources = New-TestNetworkResources
        $PublicIPs = New-TestBasicPublicIPs
        
        Write-TestLog "Creando VM con Public IP Basic (esto puede tomar varios minutos)..."
        $VM = New-TestVMWithBasicPublicIP -NetworkResources $NetworkResources -PublicIP $PublicIPs[0]
        
        Write-TestLog "✓ Recursos de prueba creados exitosamente"
    }
    
    # Verificar estado inicial
    Write-TestLog ""
    Write-TestLog "=== FASE 2: VERIFICACIÓN DE ESTADO INICIAL ==="
    $BasicPublicIPs = Test-BasicPublicIPsExist
    
    # Ejecutar migración
    Write-TestLog ""
    Write-TestLog "=== FASE 3: EJECUCIÓN DE MIGRACIÓN ==="
    $MigrationResult = Invoke-PublicIPMigrationScript -MigrationScriptPath $MigrationScript
    
    # Validar resultados
    Write-TestLog ""
    Write-TestLog "=== FASE 4: VALIDACIÓN DE RESULTADOS ==="
    $TestResult = Test-PublicIPMigrationResults
    $TestResults += $TestResult
    
    # Mostrar resumen
    Write-TestLog ""
    Write-TestLog "=== RESUMEN DE PRUEBA ==="
    if ($TestResult.Success) {
        Write-TestLog "✅ PRUEBA EXITOSA"
        Write-TestLog "VM: $($TestResult.VMName)"
        Write-TestLog "Public IPs migradas: $($TestResult.PublicIPsMigrated)"
        Write-TestLog "Nueva Public IP: $($TestResult.NewPublicIPName) ($($TestResult.NewPublicIPAddress))"
        Write-TestLog "Estado VM: $($TestResult.VMPowerState)"
    }
    else {
        Write-TestLog "❌ PRUEBA FALLIDA"
        Write-TestLog "Error: $($TestResult.Error)"
    }
    
    Write-TestLog ""
    Write-TestLog "=== FASE 5: LIMPIEZA ==="
    Remove-TestResources
    
    Write-TestLog ""
    Write-TestLog "=== PRUEBA DE MIGRACIÓN DE PUBLIC IP COMPLETADA ==="
    
    if (-not $TestResult.Success) {
        exit 1
    }
}
catch {
    Write-TestLog "Prueba falló con error crítico: $($_.Exception.Message)" -Level "ERROR"
    Write-TestLog ""
    Write-TestLog "RECURSOS QUE PUEDEN NECESITAR LIMPIEZA MANUAL:"
    Write-TestLog "- Grupo de recursos: $ResourceGroupName"
    Write-TestLog "- VM: $TestVMName"
    Write-TestLog "- Public IPs: $PublicIPName, $AdditionalPublicIPName"
    Write-TestLog ""
    exit 1
}
