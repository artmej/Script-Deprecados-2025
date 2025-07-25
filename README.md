# 🔄 Azure SKU Deprecation Migration Scripts

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://github.com/PowerShell/PowerShell)
[![Azure](https://img.shields.io/badge/Azure-Cloud-blue.svg)](https://azure.microsoft.com/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

> **🚨 IMPORTANTE**: Algunos SKUs de Azure serán deprecados el **30 de septiembre de 2025**. Este repositorio contiene herramientas automatizadas para migrar tus recursos antes de la fecha límite.

## 🎯 Objetivo

Automatizar la migración de recursos Azure que utilizan SKUs deprecados, proporcionando scripts seguros, probados y fáciles de usar que siguen las mejores prácticas de Microsoft Azure.

## 🚀 Características Principales

- ✅ **Scripts completamente automatizados** para cada tipo de migración
- 🧪 **Suite completa de tests** para validar migraciones
- 📊 **Logging detallado** con reportes de progreso
- 🛡️ **Validaciones previas** para evitar problemas
- 🔄 **Manejo de dependencias** automático
- 📋 **Procesamiento por lotes** desde archivos de Resource IDs
- 🌍 **Interfaz en español** con documentación completa

## 📋 SKUs Deprecados Cubiertos

### ✅ Completado
1. **Discos No Administrados (Unmanaged Disks)** → Discos Administrados (Managed Disks)
   - Fecha límite: 30 de septiembre de 2025
   - Script: `Convert-UnmanagedToManagedDisks.ps1`
   - Estado: ✅ Implementado

2. **Load Balancer Basic** → Load Balancer Standard
   - Fecha límite: 30 de septiembre de 2025
   - Script: `Convert-BasicToStandardLoadBalancer.ps1`
   - Estado: ✅ Implementado

3. **Public IP Basic** → Public IP Standard ⭐ **NUEVO**
   - Fecha límite: 30 de septiembre de 2025
   - Script: `Convert-BasicToStandardPublicIP.ps1`
   - Estado: ✅ Implementado
   - **Recursos soportados**: VMs, VMSS, Load Balancers, VPN Gateways, ExpressRoute Gateways, Application Gateways, Azure Databricks

> ⚠️ **ORDEN DE MIGRACIÓN CRÍTICO**: Para Public IPs, debe migrar **PRIMERO** todos los Load Balancers básicos antes de migrar las Public IPs asociadas.

### 🚧 Próximamente
- **SKUs de VM clásicas** → SKUs modernas
- **Servicios en desuso** → Servicios actualizados
- **Otros recursos deprecados** (según vayan siendo anunciados)

## 🏗️ Estructura del Proyecto

```
deprecados2/
├── scripts/
│   ├── migration/              # Scripts de migración
│   │   ├── Convert-UnmanagedToManagedDisks.ps1     # Migración de discos
│   │   ├── Convert-BasicToStandardLoadBalancer.ps1 # Migración de Load Balancer
│   │   ├── Convert-BasicToStandardPublicIP.ps1     # Migración de Public IPs
│   │   ├── Invoke-AzureResourceMigration.ps1       # 🆕 Script maestro por Resource ID
│   │   ├── MigrationUtilities.ps1                  # Utilidades para discos
│   │   ├── LoadBalancerMigrationUtilities.ps1      # Utilidades para Load Balancer
│   │   └── PublicIPMigrationUtilities.ps1          # Utilidades para Public IPs
│   ├── config/
│   │   └── MigrationConfig.ps1                     # Configuración centralizada
├── tests/                      # Scripts de prueba y validación
│   ├── Test-DiskMigration.ps1                      # Prueba migración de discos
│   ├── Test-LoadBalancerMigration.ps1              # Prueba migración de Load Balancer
│   ├── Test-PublicIPMigration.ps1                  # Prueba migración de Public IPs
│   ├── Run-AllMigrationTests.ps1                   # Ejecutar todas las pruebas
│   └── README.md                                   # Documentación de pruebas
└── README.md                   # Este archivo
```

## 🧪 Pruebas y Validación

### Scripts de Prueba Automatizados

Para validar que los scripts funcionan correctamente antes de usar en producción:

```powershell
# Ejecutar todas las pruebas
cd tests
.\Run-AllMigrationTests.ps1 -Location "East US"

# Ejecutar prueba específica
.\Test-DiskMigration.ps1 -ResourceGroupName "rg-test-disks" -Location "East US"
.\Test-LoadBalancerMigration.ps1 -ResourceGroupName "rg-test-lb" -Location "East US"  
.\Test-PublicIPMigration.ps1 -ResourceGroupName "rg-test-pip" -Location "East US"
```

### Características de las Pruebas
- 🏗️ **Crean recursos** con SKUs originales (Basic/No administrados)
- 🔄 **Ejecutan migración** automáticamente
- ✅ **Validan resultados** de la migración
- 🧹 **Limpian recursos** automáticamente
- 📊 **Generan reportes** detallados

⚠️ **Nota**: Las pruebas crean recursos reales en Azure que generan costos. Úselas en suscripciones de desarrollo.

## 🚀 Inicio Rápido

### 1. Prerrequisitos

#### PowerShell y Módulos Azure
```powershell
# Instalar módulos requeridos
Install-Module Az.Compute -Force
Install-Module Az.Resources -Force
Install-Module Az.Storage -Force
Install-Module Az.Network -Force

# Módulo específico para migración de Load Balancer
Install-Module AzureBasicLoadBalancerUpgrade -Force

# Conectar a Azure
Connect-AzAccount
```

#### Permisos Azure
- **Virtual Machine Contributor** o superior
- **Storage Account Contributor** 
- Acceso de lectura/escritura a los grupos de recursos objetivo

### 2. Configuración

1. Copiar y personalizar el archivo de configuración:
```powershell
cp .\scripts\migration\MigrationConfig.ps1 .\MyConfig.ps1
# Editar MyConfig.ps1 con tus valores específicos
```

2. Validar configuración:
```powershell
.\MyConfig.ps1
```

### 3. Ejecución

#### 🚀 Nuevo: Migración por Resource ID (Recomendado)
```powershell
# Migrar cualquier recurso usando su Resource ID
.\scripts\migration\Invoke-AzureResourceMigration.ps1 -ResourceId "/subscriptions/12345/resourceGroups/myRG/providers/Microsoft.Compute/virtualMachines/myVM"

# Migrar Load Balancer básico
.\scripts\migration\Invoke-AzureResourceMigration.ps1 -ResourceId "/subscriptions/12345/resourceGroups/myRG/providers/Microsoft.Network/loadBalancers/myLB"

# Migrar Public IP básica  
.\scripts\migration\Invoke-AzureResourceMigration.ps1 -ResourceId "/subscriptions/12345/resourceGroups/myRG/providers/Microsoft.Network/publicIPAddresses/myPIP"

# Modo de prueba (WhatIf)
.\scripts\migration\Invoke-AzureResourceMigration.ps1 -ResourceId $ResourceId -WhatIf

# Forzar sin confirmaciones
.\scripts\migration\Invoke-AzureResourceMigration.ps1 -ResourceId $ResourceId -Force
```

#### ⭐ Migración por Lotes desde Archivo
```powershell
# Migrar múltiples recursos desde archivo de texto
.\scripts\migration\Invoke-AzureResourceMigration.ps1 -ResourceIdFile ".\ResourceIds.txt"

# Con opciones adicionales para lotes grandes
.\scripts\migration\Invoke-AzureResourceMigration.ps1 -ResourceIdFile ".\ResourceIds.txt" -ContinueOnError -Force

# Usar archivo de ejemplo como plantilla
cp .\scripts\migration\ResourceIds-Example.txt .\MisRecursos.txt
# Editar MisRecursos.txt con tus Resource IDs reales
.\scripts\migration\Invoke-AzureResourceMigration.ps1 -ResourceIdFile ".\MisRecursos.txt"
```

**Formato del archivo de Resource IDs:**
```text
# Un Resource ID por línea - líneas con # son comentarios
/subscriptions/12345/resourceGroups/prod/providers/Microsoft.Compute/virtualMachines/vm1
/subscriptions/12345/resourceGroups/prod/providers/Microsoft.Network/loadBalancers/lb1
/subscriptions/12345/resourceGroups/prod/providers/Microsoft.Network/publicIPAddresses/pip1
```

**Características del procesamiento por lotes:**
- ✅ **Ordenamiento automático** por prioridades de dependencia
- ✅ **Validación de formato** de Resource IDs
- ✅ **Ignorar comentarios** y líneas vacías
- ✅ **Reportes detallados** de progreso por recurso
- ✅ **Opción continuar en error** para lotes grandes
- ✅ **Estadísticas completas** al final del proceso

#### Generar reporte de estado actual
```powershell
# Cargar utilidades para discos
. .\scripts\migration\MigrationUtilities.ps1

# Generar reporte completo de discos
Get-UnmanagedDiskReport -ExportPath ".\disks-report.csv"

# Cargar utilidades para Load Balancer  
. .\scripts\migration\LoadBalancerMigrationUtilities.ps1

# Generar reporte completo de Load Balancers
Get-BasicLoadBalancerReport -ExportPath ".\loadbalancer-report.csv"
```

#### Probar preparación para migración
```powershell
# Probar VMs para migración de discos
Test-MigrationReadiness -ResourceGroupName "mi-grupo-recursos"

# Probar Load Balancer para migración
Test-LoadBalancerMigrationReadiness -ResourceGroupName "mi-grupo-recursos" -LoadBalancerName "mi-load-balancer"
```

#### Migrar recursos (con modo de prueba)
```powershell
# Migrar discos de VMs
.\scripts\migration\Convert-UnmanagedToManagedDisks.ps1 `
    -ResourceGroupName "mi-grupo-recursos" `
    -VMName "mi-vm" `
    -WhatIf

# 2. SEGUNDO: Migrar Load Balancer básico (PRIMERO antes que Public IPs)
.\scripts\migration\Convert-BasicToStandardLoadBalancer.ps1 `
    -ResourceGroupName "mi-grupo-recursos" `
    -BasicLoadBalancerName "mi-load-balancer" `
    -ValidateScenarioOnly

# 3. TERCERO: Migrar Public IPs básicas (DESPUÉS de Load Balancers)
.\scripts\migration\Convert-BasicToStandardPublicIP.ps1 `
    -ResourceGroupName "mi-grupo-recursos" `
    -ValidateOnly
```

#### Migrar recursos (ejecución real)

##### Método 1: Script Maestro (🆕 Recomendado)
```powershell
# El script maestro detecta automáticamente el tipo de migración y dependencias
.\scripts\migration\Invoke-AzureResourceMigration.ps1 -ResourceId $ResourceId
```

##### Método 2: Scripts Individuales (Orden manual crítico)
```powershell
# 1. Migrar discos
.\scripts\migration\Convert-UnmanagedToManagedDisks.ps1 `
    -ResourceGroupName "mi-grupo-recursos" `
    -VMName "mi-vm" `
    -LogPath "C:\Logs"

# 2. Migrar Load Balancer (OBLIGATORIO ANTES de Public IPs)
.\scripts\migration\Convert-BasicToStandardLoadBalancer.ps1 `
    -ResourceGroupName "mi-grupo-recursos" `
    -BasicLoadBalancerName "mi-load-balancer"

# 3. Migrar Public IPs (SOLO DESPUÉS de Load Balancers)
.\scripts\migration\Convert-BasicToStandardPublicIP.ps1 `
    -ResourceGroupName "mi-grupo-recursos" `
    -ResourceType "VM"
```

## 📊 Funcionalidades Principales

### Script Maestro ⭐ **NUEVO**
- ✅ **Detección automática** de tipo de recurso por Resource ID
- ✅ **Análisis inteligente** de SKU y necesidad de migración
- ✅ **Validación de dependencias** críticas automática
- ✅ **Ejecución del script apropiado** según tipo de recurso
- ✅ **Orden de migración correcto** automático
- ✅ **Logging unificado** de todo el proceso
- ✅ **Soporte WhatIf** para pruebas sin cambios

### Migración de Discos
- ✅ **Conversión automática** de VMs con discos no administrados
- ✅ **Soporte para discos de datos** múltiples
- ✅ **Preservación de configuración** de VM
- ✅ **Soporte para Availability Sets** 
- ✅ **Snapshots automáticos** antes de migración
- ✅ **Logging detallado** con timestamps
- ✅ **Modo WhatIf** para pruebas sin cambios
- ✅ **Validación post-migración**

### Migración de Load Balancers
- ✅ **Migración automática** usando módulo oficial Microsoft
- ✅ **Preservación de configuración** frontend y backend
- ✅ **Validación de escenarios** no soportados
- ✅ **Planificación de conectividad** saliente
- ✅ **Respaldos automáticos** para recuperación
- ✅ **Verificación post-migración** completa

### Migración de Public IPs
- ✅ **Detección automática** de recursos asociados
- ✅ **Soporte multi-recurso**: VMs, VMSS, Gateways, Application Gateway
- ✅ **Análisis de complejidad** de migración
- ✅ **Validación de dependencias** de Load Balancer
- ✅ **Plan de migración** detallado por fases
- ✅ **Configuración zone-redundant** automática
- ✅ **Manejo especial** para recursos críticos (VPN Gateways)

### Scripts de Migración
- ✅ **Migración automatizada** con validaciones completas
- ✅ **Soporte para Availability Sets** 
- ✅ **Logging detallado** con timestamps
- ✅ **Modo WhatIf** para pruebas sin cambios
- ✅ **Manejo de errores** y reintentos automáticos
- ✅ **Validación post-migración**

### Utilidades de Soporte
- ✅ **Reportes de estado** detallados
- ✅ **Pruebas de preparación** para migración
- ✅ **Detección de VHDs huérfanos** 
- ✅ **Limpieza automática** de recursos no utilizados
- ✅ **Estimación de costos** y ahorros

### Configuración Avanzada
- ✅ **Ventanas de mantenimiento** configurables
- ✅ **Plantillas de notificación** por email
- ✅ **Configuraciones de seguridad** personalizables
- ✅ **Validación de configuración** automática

## ⚠️ Consideraciones Importantes

### 🔄 ORDEN DE MIGRACIÓN CRÍTICO

**Para evitar problemas, siga este orden exacto:**

1. **PRIMERO**: Migrar discos no administrados → administrados
2. **SEGUNDO**: Migrar Load Balancers Basic → Standard  
3. **TERCERO**: Migrar Public IPs Basic → Standard

> ⚠️ **ADVERTENCIA CRÍTICA**: NO migre Public IPs antes de migrar Load Balancers básicos. Los Load Balancers básicos que usan Public IPs básicas deben migrarse primero para evitar inconsistencias.

### Antes de la Migración

#### Para Discos
- 📅 **Planificar ventana de mantenimiento** - las VMs se desasignarán
- 🔄 **La migración NO es reversible**
- ✅ **Verificar que todas las extensiones estén en estado 'Succeeded'**
- 🔍 **Probar en entorno de desarrollo/pruebas primero**

#### Para Load Balancers
- 📅 **Planificar tiempo de inactividad** de la aplicación
- 🔄 **La migración no es completamente reversible** para LBs públicos
- 🌐 **Planificar conectividad saliente** para Load Balancers internos
- 🔒 **Remover bloqueos** del Load Balancer y recursos relacionados

#### Para Public IPs
- ⚠️ **VERIFICAR**: Todos los Load Balancers básicos ya migrados
- 🌐 **Las direcciones IP pueden cambiar** si no se puede preservar
- 📝 **Documentar configuraciones de DNS** actuales
- 🎯 **Coordinar con equipos** de red y aplicaciones

### Después de la Migración

#### Para Discos
- 💰 **Los VHDs originales seguirán generando costos** hasta eliminación manual
- 🔍 **Verificar funcionamiento de todas las aplicaciones**
- 📝 **Actualizar scripts que referencien URIs de discos antiguos**
- 💾 **Actualizar políticas de respaldo si es necesario**
- 🧹 **Limpiar VHDs huérfanos para ahorrar costos**

#### Para Load Balancers
- 🔍 **Probar conectividad entrante** a través del Load Balancer
- 🌐 **Probar conectividad saliente** desde miembros del backend pool
- 📊 **Configurar alertas** para el nuevo Standard Load Balancer
- 🔧 **Actualizar Network Security Groups** si es necesario

#### Para Public IPs
- 📝 **Actualizar registros DNS** con nuevas direcciones IP
- 🔒 **Actualizar reglas de firewall/NSG** con nuevas IPs
- 📋 **Actualizar configuraciones de aplicaciones** que usen IPs específicas
- 📊 **Configurar monitoreo** para nuevas Public IPs Standard

## 📈 Beneficios de la Migración

### Técnicos
- 🚀 **Mayor rendimiento** con discos administrados
- 🔒 **Mejor seguridad** y cifrado nativo
- 📊 **Métricas y monitoreo** mejorados
- 🔧 **Gestión simplificada** de discos
- 📸 **Snapshots automáticas** y respaldos

### Operacionales
- 💰 **Reducción de costos** a largo plazo
- ⚡ **Menor tiempo de inactividad** en operaciones
- 🎯 **Cumplimiento** con roadmap de Azure
- 🛡️ **Mayor disponibilidad** y confiabilidad

## 🔍 Solución de Problemas

### Errores Comunes

#### `SnapshotCountExceeded`
- **Causa**: Demasiadas instantáneas del disco
- **Solución**: El script reintenta automáticamente, o eliminar snapshots manualmente

#### `VM extensions not in 'Succeeded' state`
- **Causa**: Extensiones de VM en estado fallido
- **Solución**: Reparar extensiones antes de migrar

#### `Availability set fault domain count error`
- **Causa**: Limitaciones regionales de dominios de fallo
- **Solución**: El script ajusta automáticamente el número de dominios

### Contacto y Soporte
- 📁 **Revisar logs** generados por los scripts
- 📖 **Consultar documentación** oficial de Microsoft
- 🔧 **Verificar permisos** de Azure RBAC
- 📧 **Contactar al equipo** de Azure (configurar en MigrationConfig.ps1)

## 📚 Referencias y Documentación

### Microsoft Official
- [Unmanaged Disks Deprecation](https://learn.microsoft.com/azure/virtual-machines/unmanaged-disks-deprecation)
- [Convert Unmanaged to Managed Disks](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/convert-unmanaged-to-managed-disks)
- [Managed Disks Overview](https://learn.microsoft.com/en-us/azure/virtual-machines/managed-disks-overview)
- [Azure VM Best Practices](https://learn.microsoft.com/azure/virtual-machines/best-practices)

### Azure PowerShell
- [Az.Compute Module](https://docs.microsoft.com/powershell/module/az.compute)
- [ConvertTo-AzVMManagedDisk](https://docs.microsoft.com/powershell/module/az.compute/convertto-azvmmanageddisk)

## 🏷️ Versión y Compatibilidad

- **Versión**: 1.0
- **Fecha**: Enero 2025
- **PowerShell**: 5.1 o superior
- **Módulos Azure**: Az.Compute, Az.Resources, Az.Storage
- **Plataformas**: Windows PowerShell, PowerShell Core

## 🤝 Contribuciones

Este proyecto está diseñado para evolucionar según nuevos anuncios de depreciación de Azure:

1. **Fork** el repositorio
2. **Crear branch** para nueva funcionalidad
3. **Implementar** siguiendo las mejores prácticas de Azure
4. **Probar** exhaustivamente en entornos de desarrollo
5. **Documentar** cambios y casos de uso
6. **Enviar Pull Request** con descripción detallada

---

**⚡ Importante**: La migración de discos no administrados es obligatoria antes del 30 de septiembre de 2025. ¡Planifica y ejecuta tu migración con tiempo suficiente!
