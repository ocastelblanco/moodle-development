# Moodle 5.1 AWS Deployment Skills

Conjunto completo de herramientas, scripts y documentación para desplegar Moodle 5.1 en AWS de forma optimizada, segura y escalable.

## 🎯 Características

- ✅ **Infrastructure as Code** - Terraform para provisión reproducible
- ✅ **Scripts automatizados** - Deployment en minutos
- ✅ **AI Agent Skills** - Skills para Claude Code y otros agentes de IA
- ✅ **Single server optimizado** - Configuración eficiente de recursos
- ✅ **RDS MariaDB** - Base de datos administrada
- ✅ **SSL/HTTPS automático** - Let's Encrypt con renovación automática
- ✅ **Backups automatizados** - Snapshots y dumps programados
- ✅ **Monitoreo CloudWatch** - Dashboards y alarmas
- ✅ **CDN CloudFront** - Optimización de assets estáticos
- ✅ **PHP-FPM optimizado** - Configuración basada en memoria disponible
- ✅ **Sistema de actualizaciones** - Moodle auto-update configurado

## 📋 Requisitos Previos

- Cuenta AWS con permisos administrativos
- AWS CLI configurado (`aws configure`)
- Terraform >= 1.0
- SSH key pair creado en AWS
- Dominio registrado (para SSL)

## 🏗️ Arquitectura

```
┌─────────────────────────────────────────────────────┐
│                    Internet                         │
└────────────────────┬────────────────────────────────┘
                     │
            ┌────────▼────────┐
            │   Route 53      │  DNS Management
            │  (your domain)  │
            └────────┬────────┘
                     │
            ┌────────▼────────┐
            │  CloudFront     │  CDN (opcional)
            │  (assets)       │
            └────────┬────────┘
                     │
            ┌────────▼────────┐
            │  Elastic IP     │  52.x.x.x
            └────────┬────────┘
                     │
     ┌───────────────▼───────────────┐
     │       EC2 Instance            │
     │  ┌─────────────────────────┐  │
     │  │   Apache 2.4 + PHP 8.4  │  │
     │  │   ┌─────────────────┐   │  │
     │  │   │  Moodle 5.1     │   │  │
     │  │   │  (code + cache) │   │  │
     │  │   └─────────────────┘   │  │
     │  └─────────────────────────┘  │
     │  ┌─────────────────────────┐  │
     │  │   EBS Volume (Data)     │  │
     │  │   /moodledata          │  │
     │  └─────────────────────────┘  │
     └───────────────┬───────────────┘
                     │
            ┌────────▼────────┐
            │   RDS MariaDB   │
            │   10.11.15+     │
            └─────────────────┘
```

### Componentes

| Componente | Tipo | Especificación | Propósito |
|------------|------|----------------|-----------|
| **EC2** | t4g.medium/large | 2-4 vCPU, 4-8 GB RAM | Servidor web/aplicación |
| **EBS Root** | gp3 | 15 GB | Sistema operativo |
| **EBS Data** | gp3 | 25-50 GB | Moodledata (archivos usuarios) |
| **RDS** | db.t4g.micro | MariaDB 10.11.15+ | Base de datos |
| **Elastic IP** | - | IPv4 estática | Dirección pública fija |
| **CloudFront** | - | CDN global | Cache de assets estáticos |

## 🚀 Quick Start

### Opción 1: Deployment Completo Automatizado (Recomendado)

```bash
# 1. Clonar o navegar al directorio
cd skills/

# 2. Configurar variables
cp config/variables.sh.example config/variables.sh
# Editar variables.sh con tus valores

# 3. Provisionar infraestructura (Terraform)
cd terraform/
terraform init
terraform plan
terraform apply

# 4. Configurar servidor y desplegar Moodle
cd ../scripts/
./01-provision-infrastructure.sh
./02-setup-server.sh
./03-install-moodle.sh
./04-configure-ssl.sh
./05-optimize-system.sh
./06-setup-backups.sh
./07-setup-monitoring.sh
```

### Opción 2: Step-by-Step Manual

Sigue la documentación detallada en [docs/](docs/):

1. [Visión General de Arquitectura](docs/01-architecture-overview.md)
2. [Prerequisitos](docs/02-prerequisites.md)
3. [Configuración EC2](docs/03-ec2-configuration.md)
4. [Instalación de Moodle](docs/04-moodle-installation.md)
5. [Optimización del Sistema](docs/05-optimization.md)
6. [Configuración SSL](docs/06-ssl-configuration.md)
7. [Sistema de Backups](docs/07-backups.md)
8. [Monitoreo CloudWatch](docs/08-monitoring.md)
9. [Mantenimiento](docs/09-maintenance.md)

### Opción 3: AI Agent Deployment (Claude Code, ChatGPT, etc.)

Utiliza los **AI Agent Skills** para deployment autónomo con agentes de inteligencia artificial:

```bash
# Con Claude Code (CLI)
claude "Deploy production Moodle 5.1 on AWS t4g.medium with RDS MariaDB,
        SSL, backups to S3, and CloudWatch monitoring. Use the skills in
        deploy-moodle/skills/ directory"
```

O simplemente:

```
"Deploy Moodle 5.1 following the skills in deploy-moodle/skills/"
```

**El agente de IA ejecutará automáticamente:**

1. 🏗️ Provisión de infraestructura AWS (Terraform)
2. ⚙️ Configuración del servidor LAMP
3. 📦 Instalación de Moodle 5.1
4. 🔒 Configuración SSL/HTTPS
5. ⚡ Optimización del sistema
6. 💾 Setup de backups automáticos
7. 📊 Configuración de monitoreo

**Ventajas:**

- ✅ Deployment completamente autónomo
- ✅ El agente lee y ejecuta cada skill
- ✅ Troubleshooting automático de errores
- ✅ Verificación de cada paso
- ✅ ~45-60 minutos para deployment completo

**Skills disponibles:** Ver documentación completa en [skills/README.md](skills/README.md)

**Más información:** Consulta la [documentación de AI Agent Skills](skills/README.md) para:
- Lista completa de 8 skills disponibles
- Cómo usar con Claude Code, ChatGPT u otros agentes
- Ejemplos de prompts para diferentes escenarios
- Arquitectura y flujo de trabajo de los skills

## 📂 Estructura del Proyecto

```
deploy-moodle/
├── README.md                    # Este archivo
├── skills/                      # 🤖 AI Agent Skills (Claude Code, etc.)
│   ├── README.md                # Documentación de skills
│   ├── provision-infrastructure.md
│   ├── setup-moodle-server.md
│   ├── install-moodle.md
│   ├── configure-ssl.md
│   ├── optimize-system.md
│   ├── setup-backups.md
│   ├── setup-monitoring.md
│   └── troubleshoot-moodle.md
├── docs/                        # Documentación técnica detallada
│   ├── 01-architecture-overview.md
│   ├── 02-prerequisites.md
│   ├── 03-ec2-configuration.md
│   ├── 04-moodle-installation.md
│   ├── 05-optimization.md
│   ├── 06-ssl-configuration.md
│   ├── 07-backups.md
│   ├── 08-monitoring.md
│   └── 09-maintenance.md
├── terraform/                   # Infrastructure as Code
│   ├── main.tf                  # Configuración principal
│   ├── variables.tf             # Variables de entrada
│   ├── outputs.tf               # Outputs (IPs, IDs, etc)
│   ├── ec2.tf                   # Instancia EC2 + EBS
│   ├── rds.tf                   # Base de datos RDS
│   ├── security-groups.tf       # Security Groups
│   ├── cloudwatch.tf            # Alarmas y dashboards
│   └── cloudfront.tf            # CDN (opcional)
├── scripts/                     # Scripts de automatización
│   ├── 01-provision-infrastructure.sh
│   ├── 02-setup-server.sh
│   ├── 03-install-moodle.sh
│   ├── 04-configure-ssl.sh
│   ├── 05-optimize-system.sh
│   ├── 06-setup-backups.sh
│   ├── 07-setup-monitoring.sh
│   └── utilities/
│       ├── health-check.sh
│       ├── memory-monitor.sh
│       └── backup-restore.sh
├── config/                      # Archivos de configuración
│   ├── variables.sh.example
│   ├── php-fpm-optimized.conf
│   ├── apache-moodle.conf
│   └── moodle-cron
└── templates/                   # Templates y configs
    ├── config.php.template
    └── ssl-renewal.sh
```

## ⚙️ Configuración de Variables

Antes de ejecutar, configura tus variables en `config/variables.sh`:

```bash
# AWS Configuration
export AWS_PROFILE="default"
export AWS_REGION="us-east-1"
export KEY_PAIR_NAME="your-key-pair"

# Instance Configuration
export INSTANCE_TYPE="t4g.medium"  # o t4g.large
export AMI_ID="ami-xxxxxxxxx"      # Amazon Linux 2023 ARM64

# Domain Configuration
export DOMAIN_NAME="moodle.yourdomain.com"
export ADMIN_EMAIL="admin@yourdomain.com"

# Moodle Configuration
export MOODLE_VERSION="5.1"
export DB_NAME="moodle"
export DB_USER="moodleuser"
export DB_PASSWORD="your-secure-password"

# Optimization
export PHP_FPM_MAX_CHILDREN="15"   # Ajustar según RAM
export ENABLE_CLOUDFRONT="false"   # true/false
```

## 🔧 Optimizaciones Incluidas

### 1. PHP-FPM Optimizado

Configuración automática basada en memoria disponible:

| RAM Disponible | max_children | Memoria Teórica |
|----------------|--------------|-----------------|
| 4 GB (t4g.medium) | 15 | ~3 GB |
| 8 GB (t4g.large) | 35 | ~7 GB |

### 2. Apache Optimizado

- MPM Event (mejor performance que Prefork)
- KeepAlive configurado óptimamente
- Compresión mod_deflate
- Cache headers para assets estáticos

### 3. Sistema Operativo

- SWAP configurado (2 GB)
- Límites de archivos aumentados
- TCP/IP optimizado
- Firewall (firewalld) configurado

### 4. Moodle

- Cron optimizado (cada minuto)
- Cache configurado (file cache + opcache)
- Session handler: database
- Límites de subida ajustados

## 📊 Costos Estimados

### Configuración Básica (t4g.medium)

| Servicio | Especificación | Costo/mes |
|----------|----------------|-----------|
| EC2 | t4g.medium (4GB) | ~$24 |
| EBS | 15GB gp3 (root) | ~$1.50 |
| EBS | 25GB gp3 (data) | ~$2.50 |
| RDS | db.t4g.micro MariaDB | ~$12 |
| Elastic IP | 1 IP | ~$3.60 |
| CloudWatch | Alarmas básicas | ~$1 |
| **Total** | | **~$44.60/mes** |

### Configuración Mejorada (t4g.large)

| Servicio | Especificación | Costo/mes |
|----------|----------------|-----------|
| EC2 | t4g.large (8GB) | ~$48 |
| EBS | 15GB gp3 (root) | ~$1.50 |
| EBS | 50GB gp3 (data) | ~$5 |
| RDS | db.t4g.small MariaDB | ~$24 |
| Elastic IP | 1 IP | ~$3.60 |
| CloudWatch | Alarmas básicas | ~$1 |
| **Total** | | **~$83.10/mes** |

*Precios aproximados para us-east-1 (2026)*

## 🛡️ Seguridad

- Security Groups restrictivos (solo puertos necesarios)
- SSH solo desde IPs específicas (configurable)
- SSL/TLS automático con Let's Encrypt
- Secrets Manager para credenciales (opcional)
- Actualizaciones automáticas de seguridad
- Firewall configurado (firewalld)

## 📈 Monitoreo

### CloudWatch Dashboards

- Uso de CPU, memoria, disco
- Latencia de base de datos
- Tráfico de red
- Errores de aplicación

### Alarmas Configuradas

- CPU > 80% por 5 minutos
- Memoria disponible < 500 MB
- Disco > 80% utilizado
- RDS CPU > 80%
- Status check failed

### Logs

- `/var/log/httpd/` - Logs de Apache
- `/var/log/php-fpm/` - Logs de PHP-FPM
- `/var/log/moodle/` - Logs de Moodle
- `/var/log/memory-monitor.log` - Monitoreo de memoria

## 🔄 Backups

### Automáticos

- **Snapshots EBS**: Diarios a las 2 AM UTC, retención 7 días
- **Dump base de datos**: Diarios a las 3 AM UTC, retención 7 días
- **Moodledata**: Semanal, sincronizado a S3
- **RDS**: Automated backups, retención 7 días

### Manuales

```bash
# Snapshot inmediato
./scripts/utilities/backup-now.sh

# Restaurar desde backup
./scripts/utilities/backup-restore.sh <snapshot-id>
```

## 🔧 Mantenimiento

### Actualizaciones de Moodle

Sistema automático configurado:

```bash
# Verificar actualizaciones disponibles
sudo -u apache /usr/bin/php /var/www/html/moodle/admin/cli/check_database_schema.php

# Aplicar actualizaciones (manual)
cd /var/www/html/moodle
sudo -u apache git pull
sudo -u apache /usr/bin/php admin/cli/upgrade.php --non-interactive
```

### Actualizaciones del Sistema

```bash
# Amazon Linux 2023 - actualizaciones automáticas configuradas
sudo dnf update -y

# Verificar servicios después de actualizar
./scripts/utilities/health-check.sh
```

## 🤖 AI Agent Skills

Este proyecto incluye **8 skills profesionales** diseñados específicamente para agentes de inteligencia artificial como Claude Code, ChatGPT y otros asistentes con capacidades de ejecución de código.

### ¿Qué son los Skills?

Los skills son conjuntos estructurados de instrucciones que guían a los agentes de IA a través de tareas técnicas complejas. Cada skill incluye:

- **Contexto completo**: Qué hace el skill y cuándo usarlo
- **Prerequisites**: Condiciones requeridas antes de ejecutar
- **Instrucciones paso a paso**: Implementación detallada
- **Scripts de automatización**: Enlaces a scripts para ejecución rápida
- **Troubleshooting**: Soluciones a problemas comunes
- **Ejemplos reales**: Casos de uso del mundo real

### Skills Disponibles

1. **provision-infrastructure** - Provisión de infraestructura AWS con Terraform
2. **setup-moodle-server** - Instalación y configuración del stack LAMP
3. **install-moodle** - Deployment de Moodle 5.1 desde fuentes oficiales
4. **configure-ssl** - Configuración SSL/HTTPS con Let's Encrypt
5. **optimize-system** - Optimización de sistema basada en experiencia real (ACG)
6. **setup-backups** - Sistema de backups automatizado con estrategia 3-2-1
7. **setup-monitoring** - Monitoreo CloudWatch con alarmas y dashboards
8. **troubleshoot-moodle** - Diagnóstico y resolución de problemas comunes

### Uso con Agentes de IA

**Claude Code:**

```bash
claude "Deploy Moodle using skills in deploy-moodle/skills/"
```

**ChatGPT / Otros:**

- Sube los archivos de [skills/](skills/) a la conversación
- Solicita el deployment: "Deploy Moodle 5.1 siguiendo los skills"

### Ventajas del Deployment con IA

- ⚡ **Autónomo**: El agente ejecuta todos los pasos sin intervención
- 🔍 **Verificación automática**: Valida cada paso antes de continuar
- 🛠️ **Auto-troubleshooting**: Detecta y resuelve errores automáticamente
- 📊 **Reporting**: Informa progreso y resultados en tiempo real
- ⏱️ **Eficiente**: Deployment completo en 45-60 minutos

### Experiencia Real

Los skills están basados en el **proyecto ACG Calidad** (Moodle 4.1 → 5.1), incluyendo:
- Optimización de PHP-FPM que resolvió problemas de OOM
- Configuración de SWAP para estabilidad en t4g.medium
- Monitoreo de memoria que previene caídas del servicio
- Estrategias de backup probadas en producción

**Documentación completa**: [skills/README.md](skills/README.md)

## 📞 Soporte y Contribuciones

Este conjunto de herramientas está diseñado para ser modular y extensible. Puedes:

- Modificar variables para ajustar a tu caso de uso
- Agregar scripts adicionales en `scripts/utilities/`
- Extender la configuración de Terraform
- Mejorar las optimizaciones
- Crear nuevos skills para casos de uso específicos

## 📚 Referencias

- [Moodle 5.1 Documentation](https://docs.moodle.org/51/en/)
- [AWS Best Practices](https://aws.amazon.com/architecture/well-architected/)
- [PHP-FPM Optimization](https://www.php.net/manual/en/install.fpm.php)
- [Let's Encrypt](https://letsencrypt.org/docs/)

## 📝 Changelog

### v1.0.0 (2026-02-02)

- Estructura inicial de skills
- Terraform para infraestructura completa
- Scripts de deployment automatizado
- Optimización PHP-FPM basada en memoria
- SSL automático con Let's Encrypt
- Sistema de backups automatizado
- Monitoreo CloudWatch
- Documentación completa

---

**Desarrollado por:** Oliver Castelblanco (@ocastelblanco)
**Basado en:** Proyecto ACG Calidad - Actualización Moodle 4.1 → 5.1
**Fecha:** Febrero 2026
**Versión:** 1.0.0
