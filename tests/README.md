# 🧪 Scripts de Prueba - Migración SKUs Deprecados

Esta carpeta contiene scripts de prueba para validar el funcionamiento de los scripts de migración de SKUs deprecados de Azure.

## 📋 Descripción General

Los scripts de prueba crean recursos de Azure con los SKUs originales (Basic/No administrados) y luego ejecutan los scripts de migración para validar que el proceso funciona correctamente.

## 📁 Scripts Disponibles

### 🔧 Scripts de Prueba Individual

| Script | Descripción | Recursos Creados |
|--------|-------------|------------------|
| `Test-DiskMigration.ps1` | Prueba migración de discos no administrados → administrados | VM con discos VHD, Storage Account |
| `Test-LoadBalancerMigration.ps1` | Prueba migración Load Balancer Basic → Standard | Load Balancer Basic, VMs backend, Public IP Basic |
| `Test-PublicIPMigration.ps1` | Prueba migración Public IP Basic → Standard | VM con Public IP Basic |

### 🎯 Script Maestro

| Script | Descripción |
|--------|-------------|
| `Run-AllMigrationTests.ps1` | Ejecuta todas las pruebas en el orden correcto |

## 🚀 Uso Rápido

### Ejecutar Todas las Pruebas
```powershell
# Ejecutar suite completa de pruebas
.\Run-AllMigrationTests.ps1 -Location "East US"

# Con prefijo personalizado y sin limpieza
.\Run-AllMigrationTests.ps1 -Location "East US" -TestPrefix "qa" -SkipCleanup
```

### Ejecutar Pruebas Individuales
```powershell
# Prueba de migración de discos
.\Test-DiskMigration.ps1 -ResourceGroupName "rg-test-disk" -Location "East US"

# Prueba de migración de Load Balancer
.\Test-LoadBalancerMigration.ps1 -ResourceGroupName "rg-test-lb" -Location "East US"

# Prueba de migración de Public IP
.\Test-PublicIPMigration.ps1 -ResourceGroupName "rg-test-pip" -Location "East US"
```

## ⚙️ Parámetros Comunes

### Parámetros Obligatorios
- **Location**: Región de Azure donde crear los recursos de prueba
- **ResourceGroupName**: Nombre del grupo de recursos (solo scripts individuales)

### Parámetros Opcionales
- **SkipCleanup**: No eliminar recursos después de la prueba
- **TestMigrationOnly**: Solo ejecutar migración (asume recursos ya existen)
- **WhatIf**: Mostrar qué haría la prueba sin ejecutarla

## 🔄 Proceso de Cada Prueba

### 1. Test-DiskMigration.ps1
```
1. Crear Storage Account y container VHDs
2. Crear VM con discos no administrados (OS + Data)
3. Verificar discos son no administrados
4. Ejecutar script de migración
5. Validar discos ahora son administrados
6. Verificar VM funcional
7. Limpiar recursos
```

### 2. Test-LoadBalancerMigration.ps1
```
1. Crear VNet, NSG, Public IP Basic
2. Crear 2 VMs backend
3. Crear Load Balancer Basic con reglas
4. Asociar VMs al backend pool
5. Ejecutar script de migración
6. Validar Load Balancer ahora es Standard
7. Verificar configuraciones preservadas
8. Limpiar recursos
```

### 3. Test-PublicIPMigration.ps1
```
1. Crear VNet, NSG
2. Crear Public IP Basic
3. Crear VM asociada a Public IP
4. Verificar Public IP es Basic
5. Ejecutar script de migración
6. Validar Public IP ahora es Standard
7. Verificar VM funcional con nueva IP
8. Limpiar recursos
```

## ⚠️ Consideraciones Importantes

### 💰 Costos
- **Los recursos creados generan costos en Azure**
- Se recomienda usar suscripción de desarrollo/pruebas
- Usar `-SkipCleanup` solo si necesita inspeccionar recursos después

### 🕒 Tiempo de Ejecución
- **Prueba individual**: ~10-15 minutos
- **Suite completa**: ~30-45 minutos
- Crear VMs es la operación más lenta

### 🔒 Permisos Requeridos
- Contributor en la suscripción o grupo de recursos
- Permisos para crear: VMs, Load Balancers, Public IPs, Storage Accounts

## 📊 Interpretación de Resultados

### ✅ Prueba Exitosa
```
✅ PRUEBA EXITOSA
VM: vm-test-unmanaged
OS Disks migrados: 1
Data Disks migrados: 1
Estado VM: VM running
```

### ❌ Prueba Fallida
```
❌ PRUEBA FALLIDA
Error: VM no se migró correctamente - sigue siendo no administrado
```

## 🧹 Limpieza Manual

Si las pruebas fallan o se interrumpen, puede que queden recursos huérfanos:

```powershell
# Listar grupos de recursos de prueba
Get-AzResourceGroup | Where-Object { $_.ResourceGroupName -like "*test*" }

# Eliminar grupo específico
Remove-AzResourceGroup -Name "rg-test-disk-12345" -Force

# Eliminar todos los grupos de prueba (¡CUIDADO!)
Get-AzResourceGroup | Where-Object { $_.ResourceGroupName -like "*test*" } | 
    Remove-AzResourceGroup -Force
```

## 🔍 Debugging

### Logs Detallados
Cada script genera logs detallados:
- `Test-DiskMigration.ps1` → logs con prefijo `[TEST-INFO]`
- `Test-LoadBalancerMigration.ps1` → logs con prefijo `[TEST-LB-INFO]`
- `Test-PublicIPMigration.ps1` → logs con prefijo `[TEST-PIP-INFO]`
- `Run-AllMigrationTests.ps1` → logs con prefijo `[MASTER-INFO]`

### Verificación Manual
```powershell
# Verificar estado de recursos después de prueba
Get-AzVM -ResourceGroupName "rg-test" -Name "vm-test"
Get-AzDisk | Where-Object { $_.ResourceGroupName -eq "rg-test" }
Get-AzLoadBalancer -ResourceGroupName "rg-test"
Get-AzPublicIpAddress -ResourceGroupName "rg-test"
```

## 📝 Personalización

### Modificar Configuraciones de Prueba
Edite las variables en cada script para personalizar:
- Tamaños de VM (`Standard_B1s` por defecto)
- Número de VMs backend (2 por defecto)
- Credenciales de VM (`testadmin` / `Test123456!`)
- Configuraciones de red

### Agregar Nuevas Pruebas
Para agregar nuevos escenarios:
1. Copie un script existente como plantilla
2. Modifique las funciones de creación de recursos
3. Actualice `Run-AllMigrationTests.ps1` para incluir la nueva prueba

## 🎯 Casos de Uso

### Validación Pre-Producción
```powershell
# Validar scripts antes de usar en producción
.\Run-AllMigrationTests.ps1 -Location "East US" -TestPrefix "preprod"
```

### Testing de CI/CD
```powershell
# Integrar en pipeline de CI/CD
.\Run-AllMigrationTests.ps1 -Location "East US" -TestPrefix "ci" -Force
```

### Debugging de Problemas
```powershell
# Ejecutar solo la prueba problemática y mantener recursos
.\Test-DiskMigration.ps1 -ResourceGroupName "rg-debug" -Location "East US" -SkipCleanup
```

---

## 🆘 Soporte

Si encuentra problemas con las pruebas:
1. Revisar logs detallados
2. Verificar permisos de Azure
3. Confirmar que los scripts de migración existen en `../scripts/migration/`
4. Validar disponibilidad de recursos en la región seleccionada
