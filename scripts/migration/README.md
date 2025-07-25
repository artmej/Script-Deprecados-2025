# Azure VM Unmanaged to Managed Disk Migration

Este directorio contiene scripts para migrar máquinas virtuales de Azure de discos no administrados (unmanaged) a discos administrados (managed), como parte del plan de depreciación de SKUs de Azure.

## 📋 Contexto

Microsoft está deprecando los discos no administrados el 30 de septiembre de 2025. Este script automatiza la migración siguiendo las mejores prácticas oficiales de Microsoft.

## 🚀 Script Principal

### `Convert-UnmanagedToManagedDisks.ps1`

Script completo de PowerShell que automatiza la migración de VMs de discos no administrados a administrados.

#### Características:
- ✅ Soporte para VMs individuales y conjuntos de disponibilidad
- ✅ Validación de prerrequisitos y estado de VMs
- ✅ Logging detallado con timestamps
- ✅ Manejo de errores y reintentos automáticos
- ✅ Modo `WhatIf` para pruebas sin cambios
- ✅ Confirmaciones de seguridad
- ✅ Validación post-migración

## 📋 Prerrequisitos

### Módulos de PowerShell
```powershell
Install-Module Az.Compute -Force
Install-Module Az.Resources -Force
```

### Permisos de Azure
- **Virtual Machine Contributor** o superior en el grupo de recursos
- **Storage Account Contributor** para acceso a discos no administrados

### Estado de la VM
- VM debe estar en estado saludable
- Todas las extensiones en estado "Provisioning succeeded"
- Agente de Azure VM actualizado

## 🛠️ Uso

### Migrar una VM individual
```powershell
.\Convert-UnmanagedToManagedDisks.ps1 -ResourceGroupName "myResourceGroup" -VMName "myVM"
```

### Migrar todas las VMs en un grupo de recursos
```powershell
.\Convert-UnmanagedToManagedDisks.ps1 -ResourceGroupName "myResourceGroup"
```

### Migrar VMs en un conjunto de disponibilidad
```powershell
.\Convert-UnmanagedToManagedDisks.ps1 -ResourceGroupName "myResourceGroup" -AvailabilitySetName "myAvailabilitySet"
```

### Modo de prueba (sin cambios reales)
```powershell
.\Convert-UnmanagedToManagedDisks.ps1 -ResourceGroupName "myResourceGroup" -VMName "myVM" -WhatIf
```

### Ejecución sin confirmaciones
```powershell
.\Convert-UnmanagedToManagedDisks.ps1 -ResourceGroupName "myResourceGroup" -VMName "myVM" -Force
```

### Especificar ruta de logs personalizada
```powershell
.\Convert-UnmanagedToManagedDisks.ps1 -ResourceGroupName "myResourceGroup" -VMName "myVM" -LogPath "C:\Logs"
```

## 📊 Proceso de Migración

1. **Validación de prerrequisitos**
   - Verificación de módulos de PowerShell
   - Validación de contexto de Azure
   - Comprobación del grupo de recursos

2. **Descubrimiento de VMs**
   - Identificación de VMs con discos no administrados
   - Validación del estado de las VMs

3. **Migración del conjunto de disponibilidad** (si aplica)
   - Conversión a conjunto de disponibilidad administrado
   - Ajuste de dominios de fallo si es necesario

4. **Migración de VMs**
   - Desasignación de la VM
   - Conversión de discos a administrados
   - Validación post-migración

5. **Resumen y tareas post-migración**

## ⚠️ Consideraciones Importantes

### Durante la Migración
- ⏸️ **La VM será desasignada** - planificar ventana de mantenimiento
- 🔄 **La migración NO es reversible**
- 🌐 **La VM recibirá una nueva IP** (si no es estática)

### Después de la Migración
- 💰 **Los VHDs originales seguirán generando costos** hasta ser eliminados manualmente
- 🔍 **Verificar que todas las aplicaciones funcionen correctamente**
- 📝 **Actualizar scripts que referencien URIs de discos antiguos**
- 🔒 **Actualizar políticas de backup si es necesario**

## 📁 Estructura de Archivos

```
scripts/
├── migration/
│   ├── Convert-UnmanagedToManagedDisks.ps1
│   └── README.md
└── test/
    └── (scripts de prueba - próximamente)
```

## 🔍 Logging

El script genera logs detallados en formato:
```
[2025-01-24 10:30:45] [INFO] Message
[2025-01-24 10:30:46] [WARNING] Warning message
[2025-01-24 10:30:47] [ERROR] Error message
[2025-01-24 10:30:48] [SUCCESS] Success message
```

Archivo de log: `UnmanagedToManagedMigration_YYYYMMDD_HHMMSS.log`

## 🛡️ Manejo de Errores

### Errores Comunes y Soluciones

#### `SnapshotCountExceeded`
- **Causa**: Demasiadas instantáneas del disco
- **Solución**: El script reintenta automáticamente después de 30 segundos
- **Manual**: Eliminar instantáneas innecesarias

#### `VM extensions not in 'Succeeded' state`
- **Causa**: Extensiones de VM en estado fallido
- **Solución**: Reparar o reinstalar extensiones antes de migrar

#### `Availability set fault domain count error`
- **Causa**: Región con limitaciones de dominios de fallo
- **Solución**: El script ajusta automáticamente a 2 dominios de fallo

## 🔗 Referencias

- [Documentación oficial de Microsoft - Migrate to Managed Disks](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/convert-unmanaged-to-managed-disks)
- [Unmanaged Disks Deprecation](https://learn.microsoft.com/azure/virtual-machines/unmanaged-disks-deprecation)
- [Azure Managed Disks Overview](https://learn.microsoft.com/en-us/azure/virtual-machines/managed-disks-overview)

## 📞 Soporte

Para preguntas o problemas con la migración:
1. Revisar los logs generados por el script
2. Consultar la documentación oficial de Microsoft
3. Verificar el estado de las extensiones de VM
4. Comprobar permisos de Azure

## 🏷️ Versión

- **Versión**: 1.0
- **Fecha**: Enero 2025
- **Compatibilidad**: PowerShell 5.1+, Az PowerShell Module
