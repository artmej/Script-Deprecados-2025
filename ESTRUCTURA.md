# 📁 Estructura del Proyecto - Azure SKU Migration Scripts

## 🏗️ Organización de Carpetas

```
📁 deprecados2/
├── 📄 Convert-BasicToStandardPublicIP.ps1      # 🔗 Acceso directo al script principal
├── 📄 Convert-BasicToStandardLoadBalancer.ps1  # 🔗 Acceso directo al script principal  
├── 📄 Convert-UnmanagedToManagedDisks.ps1      # 🔗 Acceso directo al script principal
├── 📄 README.md                                # 📖 Documentación principal
├── 📄 ESTRUCTURA.md                            # 📋 Este archivo - Guía de estructura
├── 📄 .gitignore                               # 🚫 Archivos ignorados por Git
│
├── 📁 scripts/                                 # 🎯 Scripts principales del proyecto
│   ├── 📁 config/                             # ⚙️ Configuraciones
│   │   └── 📄 MigrationConfig.ps1             # Configuración de migración
│   │
│   └── 📁 migration/                          # 🔄 Scripts de migración (ORIGINALES)
│       ├── 📄 Convert-BasicToStandardPublicIP.ps1        # Migración Public IPs
│       ├── 📄 Convert-BasicToStandardLoadBalancer.ps1    # Migración Load Balancers
│       ├── 📄 Convert-UnmanagedToManagedDisks.ps1        # Migración Discos
│       ├── 📄 Invoke-AzureResourceMigration.ps1          # Orquestador principal
│       ├── 📄 MigrationConfig.ps1                        # Configuración específica
│       ├── 📄 MigrationUtilities.ps1                     # Utilidades generales
│       ├── 📄 PublicIPMigrationUtilities.ps1             # Utilidades Public IP
│       └── 📄 LoadBalancerMigrationUtilities.ps1         # Utilidades Load Balancer
│
├── 📁 tests/                                  # 🧪 Scripts de prueba y validación
│   ├── 📄 Check-TestResources.ps1            # Verificación de recursos de prueba
│   ├── 📄 Run-AllMigrationTests.ps1          # Ejecutor de todas las pruebas
│   ├── 📄 Test-BasicFunctionality.ps1        # Pruebas básicas de funcionalidad
│   ├── 📄 Test-DiskMigration.ps1             # Pruebas específicas de discos
│   ├── 📄 Test-LoadBalancerMigration.ps1     # Pruebas específicas de Load Balancers
│   └── 📄 Test-PublicIPMigration.ps1         # Pruebas específicas de Public IPs
│
├── 📁 logs/                                   # 📋 Logs de ejecución (ignorados por Git)
│   ├── 📁 migration/                         # Logs de migraciones
│   ├── 📁 test/                              # Logs de pruebas
│   └── 📁 backup/                            # Logs de backups
│
└── 📁 backups/                               # 💾 Respaldos automáticos (ignorados por Git)
```

## 🎯 Uso Recomendado

### Para Usuarios Finales (Ejecución Rápida)
```powershell
# Ejecutar desde la raíz del proyecto
.\Convert-BasicToStandardPublicIP.ps1 -ResourceGroupName "mi-rg" -WhatIf
.\Convert-BasicToStandardLoadBalancer.ps1 -ResourceGroupName "mi-rg" -WhatIf  
.\Convert-UnmanagedToManagedDisks.ps1 -ResourceGroupName "mi-rg" -WhatIf
```

### Para Desarrolladores y Mantenimiento
```powershell
# Scripts originales en ubicación organizada
.\scripts\migration\Convert-BasicToStandardPublicIP.ps1
.\scripts\migration\Convert-BasicToStandardLoadBalancer.ps1
.\scripts\migration\Convert-UnmanagedToManagedDisks.ps1

# Pruebas y validación
.\tests\Run-AllMigrationTests.ps1
.\tests\Check-TestResources.ps1
```

## 📋 Convenciones de Archivos

### 🔗 Enlaces en Raíz
- Los scripts principales tienen **accesos directos** en la raíz para facilidad de uso
- Los archivos originales están en `scripts/migration/` para organización
- Cualquier cambio debe hacerse en los archivos originales

### 🚫 Archivos Ignorados por Git
- `logs/` - Todos los archivos de log de ejecución
- `backups/` - Respaldos automáticos de configuraciones
- `*.log` - Archivos de log individuales
- `*_backup_*.json` - Archivos de backup JSON
- `migration-report-*.html` - Reportes de migración
- `test-results/` - Resultados de pruebas

### 📝 Logs Organizados
- **Migration Logs**: `logs/migration/BasicToStandardPublicIP_YYYYMMDD_HHMMSS.log`
- **Test Logs**: `logs/test/Test_SCRIPT_YYYYMMDD_HHMMSS.log`
- **Backup Logs**: `logs/backup/Backup_RESOURCE_YYYYMMDD_HHMMSS.log`

## 🔄 Flujo de Trabajo

1. **Desarrollo**: Editar scripts en `scripts/migration/`
2. **Pruebas**: Ejecutar tests desde `tests/`
3. **Ejecución**: Usar enlaces directos desde la raíz
4. **Logs**: Revisar en `logs/` por tipo de operación
5. **Backups**: Verificar en `backups/` si es necesario

## ✅ Ventajas de Esta Estructura

- ✅ **Fácil acceso**: Scripts principales disponibles en la raíz
- ✅ **Organización clara**: Cada tipo de archivo en su lugar
- ✅ **Desarrollo limpio**: Archivos originales organizados
- ✅ **Git optimizado**: Logs y backups no saturan el repositorio
- ✅ **Escalabilidad**: Estructura preparada para crecimiento del proyecto
