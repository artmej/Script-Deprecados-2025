#Requires -Version 5.1
#Requires -Modules Az.Compute, Az.Resources, Az.Storage

<#
.SYNOPSIS
    Script de prueba para migración de discos no administrados a administrados.

.DESCRIPTION
    Este script crea recursos de prueba con discos no administrados y luego
    ejecuta el script de migración para probar el proceso completo.
    
    El proceso incluye:
    1. Crear storage account y container para VHDs
    2. Crear VM con discos no administrados
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

.EXAMPLE
    .\Test-DiskMigration.ps1 -ResourceGroupName "rg-test-migration" -Location "East US"

.NOTES
    Este script es para PRUEBAS ÚNICAMENTE.
    Los recursos creados generarán costos en Azure.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$TestVMName = "vm-test-unmanaged",

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCleanup,

    [Parameter(Mandatory = $false)]
    [switch]$TestMigrationOnly
)

# Variables globales para el test
$StorageAccountName = "sttest$(Get-Random -Minimum 1000 -Maximum 9999)"
$VNetName = "vnet-test-migration"
$SubnetName = "subnet-test"
$PublicIPName = "pip-test-vm"
$NSGName = "nsg-test-vm"
$NICName = "nic-test-vm"
$TestResults = @()

# Función para logging
function Write-TestLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "[$Timestamp] [TEST-$Level] $Message"
    Write-Host $LogMessage
}

function Test-Prerequisites {
    Write-TestLog "Verificando prerequisitos de prueba..."
    
    # Verificar que existe el script de migración
    $MigrationScript = Join-Path (Split-Path $PSScriptRoot -Parent) "scripts\migration\Convert-UnmanagedToManagedDisks.ps1"
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

function New-TestStorageAccount {
    Write-TestLog "Creando storage account para VHDs: $StorageAccountName"
    
    try {
        $StorageAccount = New-AzStorageAccount `
            -ResourceGroupName $ResourceGroupName `
            -Name $StorageAccountName `
            -Location $Location `
            -SkuName "Standard_LRS" `
            -Kind "Storage"
        
        # Crear container para VHDs
        $StorageContext = $StorageAccount.Context
        $Container = New-AzStorageContainer -Name "vhds" -Context $StorageContext -Permission Blob
        
        Write-TestLog "✓ Storage account creado: $StorageAccountName"
        return $StorageAccount
    }
    catch {
        Write-TestLog "Error creando storage account: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function New-TestNetworkResources {
    Write-TestLog "Creando recursos de red de prueba..."
    
    try {
        # Crear NSG
        $NSG = New-AzNetworkSecurityGroup `
            -ResourceGroupName $ResourceGroupName `
            -Location $Location `
            -Name $NSGName
        
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
        
        # Crear Public IP (Basic para simular entorno legacy)
        $PublicIP = New-AzPublicIpAddress `
            -ResourceGroupName $ResourceGroupName `
            -Location $Location `
            -Name $PublicIPName `
            -AllocationMethod Dynamic `
            -Sku Basic
        
        # Crear Network Interface
        $NIC = New-AzNetworkInterface `
            -ResourceGroupName $ResourceGroupName `
            -Location $Location `
            -Name $NICName `
            -SubnetId $VNet.Subnets[0].Id `
            -PublicIpAddressId $PublicIP.Id
        
        Write-TestLog "✓ Recursos de red creados"
        return @{
            VNet = $VNet
            Subnet = $VNet.Subnets[0]
            PublicIP = $PublicIP
            NIC = $NIC
            NSG = $NSG
        }
    }
    catch {
        Write-TestLog "Error creando recursos de red: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function New-TestVMWithUnmanagedDisks {
    param(
        [object]$StorageAccount,
        [object]$NetworkResources
    )
    
    Write-TestLog "Creando VM de prueba con discos no administrados: $TestVMName"
    
    try {
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
        $VMConfig = Add-AzVMNetworkInterface -VM $VMConfig -Id $NetworkResources.NIC.Id
        
        # Configurar disco no administrado (OS Disk)
        $StorageContext = $StorageAccount.Context
        $OSDiskUri = "https://$($StorageAccount.StorageAccountName).blob.core.windows.net/vhds/$TestVMName-osdisk.vhd"
        
        $VMConfig = Set-AzVMOSDisk `
            -VM $VMConfig `
            -Name "$TestVMName-osdisk" `
            -VhdUri $OSDiskUri `
            -CreateOption FromImage
        
        # Agregar disco de datos no administrado
        $DataDiskUri = "https://$($StorageAccount.StorageAccountName).blob.core.windows.net/vhds/$TestVMName-datadisk1.vhd"
        
        $VMConfig = Add-AzVMDataDisk `
            -VM $VMConfig `
            -Name "$TestVMName-datadisk1" `
            -VhdUri $DataDiskUri `
            -Lun 0 `
            -DiskSizeInGB 32 `
            -CreateOption Empty
        
        # Crear la VM
        Write-TestLog "Creando VM... (esto puede tomar varios minutos)"
        $VM = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $VMConfig
        
        Write-TestLog "✓ VM creada con discos no administrados: $TestVMName"
        Write-TestLog "  OS Disk: $OSDiskUri"
        Write-TestLog "  Data Disk: $DataDiskUri"
        
        return $VM
    }
    catch {
        Write-TestLog "Error creando VM: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Test-UnmanagedDisksExist {
    Write-TestLog "Verificando que la VM tiene discos no administrados..."
    
    try {
        $VM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $TestVMName
        
        # Verificar OS disk
        if ($VM.StorageProfile.OsDisk.ManagedDisk) {
            throw "VM ya tiene OS disk administrado"
        }
        
        # Verificar data disks
        foreach ($DataDisk in $VM.StorageProfile.DataDisks) {
            if ($DataDisk.ManagedDisk) {
                throw "VM ya tiene discos de datos administrados"
            }
        }
        
        Write-TestLog "✓ VM confirmada con discos no administrados"
        Write-TestLog "  OS Disk VHD: $($VM.StorageProfile.OsDisk.Vhd.Uri)"
        
        foreach ($DataDisk in $VM.StorageProfile.DataDisks) {
            Write-TestLog "  Data Disk VHD: $($DataDisk.Vhd.Uri)"
        }
        
        return $true
    }
    catch {
        Write-TestLog "Error verificando discos: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Invoke-MigrationScript {
    param([string]$MigrationScriptPath)
    
    Write-TestLog "Ejecutando script de migración..."
    
    try {
        $MigrationParams = @{
            ResourceGroupName = $ResourceGroupName
            VMName = $TestVMName
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

function Test-MigrationResults {
    Write-TestLog "Validando resultados de migración..."
    
    try {
        # Esperar un momento para que se apliquen los cambios
        Start-Sleep -Seconds 30
        
        $VM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $TestVMName
        
        # Verificar OS disk
        if (-not $VM.StorageProfile.OsDisk.ManagedDisk) {
            throw "OS disk no se migró correctamente - sigue siendo no administrado"
        }
        
        Write-TestLog "✓ OS disk migrado exitosamente"
        Write-TestLog "  Managed Disk ID: $($VM.StorageProfile.OsDisk.ManagedDisk.Id)"
        
        # Verificar data disks
        foreach ($DataDisk in $VM.StorageProfile.DataDisks) {
            if (-not $DataDisk.ManagedDisk) {
                throw "Data disk LUN $($DataDisk.Lun) no se migró correctamente"
            }
            Write-TestLog "✓ Data disk LUN $($DataDisk.Lun) migrado exitosamente"
            Write-TestLog "  Managed Disk ID: $($DataDisk.ManagedDisk.Id)"
        }
        
        # Verificar que la VM esté corriendo
        $VMStatus = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $TestVMName -Status
        $PowerState = ($VMStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
        
        Write-TestLog "Estado de la VM: $PowerState"
        
        # Recopilar métricas de la migración
        $TestResult = [PSCustomObject]@{
            TestName = "DiskMigration"
            VMName = $TestVMName
            ResourceGroup = $ResourceGroupName
            Success = $true
            OSDisksCount = 1
            DataDisksCount = $VM.StorageProfile.DataDisks.Count
            VMPowerState = $PowerState
            MigrationTime = Get-Date
            Notes = "Migración exitosa de discos no administrados a administrados"
        }
        
        return $TestResult
    }
    catch {
        Write-TestLog "Error validando migración: $($_.Exception.Message)" -Level "ERROR"
        
        $TestResult = [PSCustomObject]@{
            TestName = "DiskMigration"
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
    Write-TestLog "=== INICIANDO PRUEBA DE MIGRACIÓN DE DISCOS ==="
    Write-TestLog "Grupo de recursos: $ResourceGroupName"
    Write-TestLog "VM de prueba: $TestVMName"
    Write-TestLog "Ubicación: $Location"
    Write-TestLog ""
    
    # Prerequisitos
    $MigrationScript = Test-Prerequisites
    
    if (-not $TestMigrationOnly) {
        # Crear recursos de prueba
        Write-TestLog "=== FASE 1: CREACIÓN DE RECURSOS DE PRUEBA ==="
        
        $ResourceGroup = New-TestResourceGroup
        $StorageAccount = New-TestStorageAccount
        $NetworkResources = New-TestNetworkResources
        $VM = New-TestVMWithUnmanagedDisks -StorageAccount $StorageAccount -NetworkResources $NetworkResources
        
        Write-TestLog "✓ Recursos de prueba creados exitosamente"
    }
    
    # Verificar estado inicial
    Write-TestLog ""
    Write-TestLog "=== FASE 2: VERIFICACIÓN DE ESTADO INICIAL ==="
    Test-UnmanagedDisksExist
    
    # Ejecutar migración
    Write-TestLog ""
    Write-TestLog "=== FASE 3: EJECUCIÓN DE MIGRACIÓN ==="
    $MigrationResult = Invoke-MigrationScript -MigrationScriptPath $MigrationScript
    
    # Validar resultados
    Write-TestLog ""
    Write-TestLog "=== FASE 4: VALIDACIÓN DE RESULTADOS ==="
    $TestResult = Test-MigrationResults
    $TestResults += $TestResult
    
    # Mostrar resumen
    Write-TestLog ""
    Write-TestLog "=== RESUMEN DE PRUEBA ==="
    if ($TestResult.Success) {
        Write-TestLog "✅ PRUEBA EXITOSA"
        Write-TestLog "VM: $($TestResult.VMName)"
        Write-TestLog "OS Disks migrados: $($TestResult.OSDisksCount)"
        Write-TestLog "Data Disks migrados: $($TestResult.DataDisksCount)"
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
    Write-TestLog "=== PRUEBA DE MIGRACIÓN DE DISCOS COMPLETADA ==="
    
    if (-not $TestResult.Success) {
        exit 1
    }
}
catch {
    Write-TestLog "Prueba falló con error crítico: $($_.Exception.Message)" -Level "ERROR"
    Write-TestLog ""
    Write-TestLog "RECURSOS QUE PUEDEN NECESITAR LIMPIEZA MANUAL:"
    Write-TestLog "- Grupo de recursos: $ResourceGroupName"
    Write-TestLog "- Storage account: $StorageAccountName"
    Write-TestLog "- VM: $TestVMName"
    Write-TestLog ""
    exit 1
}
