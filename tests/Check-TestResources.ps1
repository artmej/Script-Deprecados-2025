# Script para verificar el estado de los recursos de prueba
$TestResourceGroup = "rg-migration-test-0725"

Write-Host "🔍 VERIFICANDO RECURSOS DE PRUEBA" -ForegroundColor Cyan
Write-Host "Grupo de recursos: $TestResourceGroup" -ForegroundColor Yellow
Write-Host ""

# Verificar si el grupo de recursos existe
$RG = Get-AzResourceGroup -Name $TestResourceGroup -ErrorAction SilentlyContinue
if ($RG) {
    Write-Host "✅ Grupo de recursos encontrado" -ForegroundColor Green
    
    # Listar todos los recursos
    $Resources = Get-AzResource -ResourceGroupName $TestResourceGroup
    
    Write-Host ""
    Write-Host "📋 RECURSOS ENCONTRADOS:" -ForegroundColor Yellow
    foreach ($Resource in $Resources) {
        $StatusIcon = switch ($Resource.ResourceType) {
            "Microsoft.Compute/virtualMachines" { "🖥️" }
            "Microsoft.Storage/storageAccounts" { "💾" }
            "Microsoft.Network/virtualNetworks" { "🌐" }
            "Microsoft.Network/publicIPAddresses" { "🌍" }
            "Microsoft.Network/loadBalancers" { "⚖️" }
            "Microsoft.Network/networkInterfaces" { "🔌" }
            "Microsoft.Network/networkSecurityGroups" { "🛡️" }
            default { "📦" }
        }
        
        Write-Host "   $StatusIcon $($Resource.Name) ($($Resource.ResourceType))" -ForegroundColor White
    }
    
    Write-Host ""
    Write-Host "📊 RESUMEN:" -ForegroundColor Yellow
    Write-Host "   Total recursos: $($Resources.Count)" -ForegroundColor White
    
    # Verificar VMs específicamente
    $VMs = $Resources | Where-Object { $_.ResourceType -eq "Microsoft.Compute/virtualMachines" }
    if ($VMs) {
        Write-Host ""
        Write-Host "🖥️ MÁQUINAS VIRTUALES:" -ForegroundColor Yellow
        foreach ($VM in $VMs) {
            try {
                $VMDetails = Get-AzVM -ResourceGroupName $TestResourceGroup -Name $VM.Name
                $PowerState = (Get-AzVM -ResourceGroupName $TestResourceGroup -Name $VM.Name -Status).Statuses | 
                             Where-Object { $_.Code -like "PowerState/*" } | 
                             Select-Object -ExpandProperty DisplayStatus
                
                Write-Host "   📟 $($VM.Name): $PowerState" -ForegroundColor White
                
                # Verificar tipo de discos
                if ($VMDetails.StorageProfile.OsDisk.ManagedDisk) {
                    Write-Host "       💾 OS Disk: ADMINISTRADO ✅" -ForegroundColor Green
                } else {
                    Write-Host "       💾 OS Disk: NO ADMINISTRADO (LEGACY) ⚠️" -ForegroundColor Yellow
                }
                
                foreach ($DataDisk in $VMDetails.StorageProfile.DataDisks) {
                    if ($DataDisk.ManagedDisk) {
                        Write-Host "       💿 Data Disk LUN $($DataDisk.Lun): ADMINISTRADO ✅" -ForegroundColor Green
                    } else {
                        Write-Host "       💿 Data Disk LUN $($DataDisk.Lun): NO ADMINISTRADO (LEGACY) ⚠️" -ForegroundColor Yellow
                    }
                }
            }
            catch {
                Write-Host "   ❌ Error obteniendo detalles de $($VM.Name): $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    
    # Verificar Public IPs
    $PIPs = $Resources | Where-Object { $_.ResourceType -eq "Microsoft.Network/publicIPAddresses" }
    if ($PIPs) {
        Write-Host ""
        Write-Host "🌍 PUBLIC IPs:" -ForegroundColor Yellow
        foreach ($PIP in $PIPs) {
            try {
                $PIPDetails = Get-AzPublicIpAddress -ResourceGroupName $TestResourceGroup -Name $PIP.Name
                $SKUType = if ($PIPDetails.Sku.Name -eq "Basic") { "BÁSICO (LEGACY) ⚠️" } else { "STANDARD ✅" }
                Write-Host "   🌐 $($PIP.Name): $SKUType" -ForegroundColor White
                Write-Host "       IP: $($PIPDetails.IpAddress)" -ForegroundColor Gray
            }
            catch {
                Write-Host "   ❌ Error obteniendo detalles de $($PIP.Name): $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    
    # Verificar Load Balancers
    $LBs = $Resources | Where-Object { $_.ResourceType -eq "Microsoft.Network/loadBalancers" }
    if ($LBs) {
        Write-Host ""
        Write-Host "⚖️ LOAD BALANCERS:" -ForegroundColor Yellow
        foreach ($LB in $LBs) {
            try {
                $LBDetails = Get-AzLoadBalancer -ResourceGroupName $TestResourceGroup -Name $LB.Name
                $SKUType = if ($LBDetails.Sku.Name -eq "Basic") { "BÁSICO (LEGACY) ⚠️" } else { "STANDARD ✅" }
                Write-Host "   ⚖️ $($LB.Name): $SKUType" -ForegroundColor White
            }
            catch {
                Write-Host "   ❌ Error obteniendo detalles de $($LB.Name): $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    
} else {
    Write-Host "❌ Grupo de recursos no encontrado: $TestResourceGroup" -ForegroundColor Red
}

Write-Host ""
Write-Host "🎯 PRÓXIMOS PASOS PARA MIGRACIÓN:" -ForegroundColor Cyan
Write-Host "1. 💾 Si hay discos NO ADMINISTRADOS → .\scripts\migration\Convert-UnmanagedToManagedDisks.ps1" -ForegroundColor White
Write-Host "2. ⚖️ Si hay Load Balancers BÁSICOS → .\scripts\migration\Convert-BasicToStandardLoadBalancer.ps1" -ForegroundColor White  
Write-Host "3. 🌍 Si hay Public IPs BÁSICOS → .\scripts\migration\Convert-BasicToStandardPublicIP.ps1" -ForegroundColor White
Write-Host "4. 🚀 O usar script maestro → .\scripts\migration\Invoke-AzureResourceMigration.ps1 -ResourceId 'resource-id'" -ForegroundColor White
Write-Host ""
