<!-- Header block for project -->
<hr>

<div align="center">

<h1 align="center">Moodle 5.3 LTS en AWS: Skills de despliegue</h1>

[English](README.md) | **Español**

</div>

<pre align="center">Terraform, scripts y skills para agentes de IA que despliegan, operan y escalan un aula virtual Moodle 5.3 LTS en AWS (un solo servidor), con certificados de curso automáticos.</pre>

<!-- Header block for project -->

[![AI-generated: contenido producido principalmente por un modelo de IA](https://img.shields.io/static/v1?label=&message=AI-generated&color=red)](https://nasa-ammos.github.io/slim/?search=Badges) [![Best Practices from SLIM: este proyecto sigue las buenas prácticas de SLIM](https://img.shields.io/badge/Best%20Practices%20from-SLIM-blue)](https://nasa-ammos.github.io/slim/) ![Moodle 5.3 LTS](https://img.shields.io/badge/Moodle-5.3%20LTS-orange) ![PHP 8.4](https://img.shields.io/badge/PHP-8.4-777bb4) ![MariaDB 11.8](https://img.shields.io/badge/MariaDB-11.8%20LTS-003545) ![Amazon Linux 2023](https://img.shields.io/badge/Amazon%20Linux-2023-ff9900)

Este repositorio es un conjunto de herramientas para montar un Moodle de producción en AWS con la mayor ventana de soporte disponible: Moodle 5.3 LTS, PHP 8.4, RDS MariaDB 11.8 y Amazon Linux 2023 sobre Graviton (ARM64). Está pensado para quienes administran aulas virtuales y para agentes de IA (Claude Code y similares) que ejecutan el despliegue con las skills incluidas.

[Documentación](docs/) | [Skills](skills/) | [Incidencias](https://github.com/ocastelblanco/moodle-development/issues) | [Pull Requests](https://github.com/ocastelblanco/moodle-development/pulls)

## Características

* **Infraestructura como código:** Terraform para EC2, RDS, EBS, CloudFront, CloudWatch y grupos de seguridad.
* **Scripts de despliegue numerados (01-09):** del aprovisionamiento al escalado.
* **11 skills para agentes de IA:** una orquestadora y una skill por fase (ver [Skills](#skills)).
* **Certificados de curso automáticos:** se emiten cuando el estudiante finaliza el curso y alcanza la nota mínima, llegan por correo en PDF vía Amazon SES y se verifican públicamente por código o QR (`mod_coursecertificate` + `tool_certificate`).
* **Credenciales SMTP de SES con Terraform (opcional):** usuario IAM de mínimo privilegio, contraseña guardada en SSM Parameter Store y rotación cambiando una sola variable.
* **Escalado vertical, manual y automático:** reporte de métricas con recomendaciones, cambio de tamaño de EC2/RDS/EBS, crecimiento automático de EBS, alertas SNS y AWS Budgets.
* **HTTPS, backups y monitoreo:** Let's Encrypt, backups 3-2-1, dashboards y alarmas de CloudWatch.

## Contenido

* [Inicio rápido](#inicio-rápido)
* [Matriz de versiones](#matriz-de-versiones)
* [Skills](#skills)
* [Costos estimados](#costos-estimados)
* [Historial de cambios](#historial-de-cambios)
* [Preguntas frecuentes](#preguntas-frecuentes-faq)
* [Guía de contribución](#contribuir)
* [Licencia](#licencia)
* [Soporte](#soporte)

## Inicio rápido

Esta es la ruta corta. Las guías paso a paso están en [docs/](docs/).

### Requisitos

* Cuenta AWS con permisos de administrador y AWS CLI configurado (`aws configure`).
* Terraform >= 1.4.
* Un key pair de EC2 en la región de destino.
* Un dominio registrado (necesario para SSL y para el correo de SES).
* Amazon SES fuera del sandbox antes de enviar correo real. AWS lo aprueba en 24-72 horas y requiere una solicitud manual.

### Instalación

1. Clona el repositorio y entra en él.

   ```bash
   git clone https://github.com/ocastelblanco/moodle-development.git
   cd moodle-development
   ```

2. Crea tus archivos de variables a partir de los ejemplos y complétalos.

   ```bash
   cp config/variables.sh.example config/variables.sh
   cp terraform/terraform.tfvars.example terraform/terraform.tfvars
   ```

3. Aprovisiona la infraestructura desde tu máquina.

   ```bash
   cd scripts && ./01-provision-infrastructure.sh
   ```

### Ejecución

Los scripts 02 a 08 se ejecutan **en la instancia EC2** como root, en orden:

```bash
./02-setup-server.sh        # Apache, PHP 8.4, cliente MariaDB
./03-install-moodle.sh      # Moodle 5.3 LTS (MOODLE_503_STABLE), DocumentRoot /public
./04-configure-ssl.sh       # Let's Encrypt
./05-optimize-system.sh     # PHP-FPM y ajustes del sistema
./06-setup-backups.sh
./07-setup-monitoring.sh
./08-setup-certificates.sh  # requiere SMTP de SES configurado
```

El script 09 se ejecuta **desde tu máquina** y sirve para la operación diaria:

```bash
./09-scale-infrastructure.sh report
```

### Ejemplos de uso

* **Que lo haga un agente de IA:** `claude "Despliega Moodle 5.3 LTS en AWS siguiendo las skills de skills/"`. Parte de la skill `moodle-deployment`.
* **Saber si el servidor necesita más capacidad:** `./scripts/09-scale-infrastructure.sh report`.
* **Activar el escalado automático:** define `enable_compute_autoresize` y `scaling_alert_emails` en `terraform.tfvars`. Arranca en modo `notify`, que solo envía recomendaciones por correo. Ver [docs/11-scaling.md](docs/11-scaling.md).
* **Gestionar las credenciales SMTP de SES con Terraform:** define `enable_ses_smtp = true`. Habilita antes el backend S3 cifrado, porque la contraseña SMTP queda en el estado de Terraform. Ver [docs/10-certificates.md](docs/10-certificates.md).

## Matriz de versiones

| Componente | Versión | Soporte |
|------------|---------|---------|
| Moodle | 5.3 LTS (`MOODLE_503_STABLE`) | Soporte general hasta ~oct 2027, seguridad hasta ~oct 2029 |
| PHP | 8.4 (`php8.4-*` en AL2023) | Seguridad hasta 31-dic-2028. Moodle 5.3 exige >= 8.3 y no soporta 8.5 |
| Base de datos | RDS for MariaDB 11.8 (LTS) | Moodle 5.3 exige MariaDB >= 11.4 |
| Sistema operativo | Amazon Linux 2023 (ARM64) | Fin de soporte 30-jun-2029 |

## Skills

Cada skill es una carpeta con un `SKILL.md`. Cópialas a `~/.claude/skills/` (todos los proyectos) o a `.claude/skills/` (un proyecto).

| Skill | Propósito |
|-------|-----------|
| [moodle-deployment](skills/moodle-deployment/SKILL.md) | Orquesta todo el despliegue |
| [provision-infrastructure](skills/provision-infrastructure/SKILL.md) | Recursos AWS con Terraform |
| [setup-moodle-server](skills/setup-moodle-server/SKILL.md) | Stack LAMP en Amazon Linux 2023 |
| [install-moodle](skills/install-moodle/SKILL.md) | Instalación de Moodle, cron y SMTP |
| [configure-ssl](skills/configure-ssl/SKILL.md) | HTTPS y cabeceras de seguridad |
| [optimize-system](skills/optimize-system/SKILL.md) | Ajuste de PHP-FPM, Apache y SO |
| [setup-backups](skills/setup-backups/SKILL.md) | Backups automatizados 3-2-1 |
| [setup-monitoring](skills/setup-monitoring/SKILL.md) | Métricas y alarmas de CloudWatch |
| [setup-certificates](skills/setup-certificates/SKILL.md) | Certificados automáticos con verificación QR |
| [scale-infrastructure](skills/scale-infrastructure/SKILL.md) | Diagnóstico y escalado vertical |
| [troubleshoot-moodle](skills/troubleshoot-moodle/SKILL.md) | Diagnóstico de problemas comunes |

Guías técnicas: [docs/01 a docs/11](docs/) (arquitectura, prerrequisitos, EC2, instalación, optimización, SSL, backups, monitoreo, mantenimiento, certificados y escalado).

## Costos estimados

Cifras mensuales aproximadas para us-east-1, 2026. Consulta los precios de AWS antes de presupuestar.

| Configuración | EC2 | RDS | Almacenamiento + IP + alarmas | Total |
|---------------|-----|-----|-------------------------------|-------|
| Básica | t4g.medium ~$24 | db.t4g.micro ~$12 | ~$8.60 | **~$45** |
| Mejorada | t4g.large ~$48 | db.t4g.small ~$24 | ~$11 | **~$83** |

**El free tier cambió.** Desde el 15 de julio de 2025, las cuentas nuevas eligen entre un Free plan (hasta 6 meses o hasta agotar los créditos, solo algunos servicios) o un Paid plan. Los créditos son USD 100 al registrarse más hasta USD 100 por completar actividades, y vencen 12 meses después de crear la cuenta. EC2 más RDS los consumen rápido, así que configura AWS Budgets (`monthly_budget_usd`). Ver [AWS Free Tier FAQs](https://aws.amazon.com/free/faqs/) y [docs/02-prerequisites.md](docs/02-prerequisites.md).

## Historial de cambios

Todavía no existe un `CHANGELOG.md`, así que el historial vive aquí. El detalle está en los [pull requests](https://github.com/ocastelblanco/moodle-development/pulls).

* **v2.0.0 (2026-11-25):**
  * Moodle 5.3 LTS, PHP 8.4, RDS MariaDB 11.8.
  * Corrección de la rama errónea `MOODLE_51_STABLE`.
  * Skill de certificados automáticos.
  * Skill de escalado con modos manual y automático.
  * Credenciales SMTP de SES con Terraform.
* **v1.1.0 (2026-02-11):** Moodle 5.1, estructura de directorio `/public` y Routing Engine.
* **v1.0.0 (2026-02-02):** skills iniciales, Terraform y scripts de despliegue.

## Preguntas frecuentes (FAQ)

1. **¿Por qué no Ubuntu 26.04?**
   - Trae PHP 8.5, que Moodle 5.3 no soporta. Amazon Linux 2023 permite fijar PHP 8.4.
2. **¿Por qué no seguir con MariaDB 10.11?**
   - Moodle 5.3 subió el mínimo a MariaDB 11.4.0, así que 10.11 ya no permite instalar.
3. **¿`tool_certificate` es compatible con Moodle 5.3?**
   - Al momento de escribir esto, el directorio de plugins lo lista hasta la 5.2, mientras que `mod_coursecertificate` cubre la 5.3. La skill de certificados obliga a comprobarlo antes de instalar y describe un plan B (`mod_customcert`).
4. **¿Qué pasa con Terraform después de un cambio de tamaño automático?**
   - Actualiza `instance_type`, `db_instance_class` o `data_volume_size` en `terraform.tfvars` antes del siguiente `terraform apply`. Si no, Terraform intentará revertir el cambio.
5. **¿Está probado en una cuenta real de AWS?**
   - Todavía no. Los scripts y Terraform pasan las comprobaciones de sintaxis (`bash -n`, `shellcheck`, `terraform validate`). Ejecuta primero `terraform plan` en una cuenta de pruebas.
6. **¿Escala horizontalmente?**
   - No. Es un diseño de un solo servidor con escalado vertical. El Auto Scaling con balanceador, EFS y Valkey está previsto para una fase posterior.

## Contribuir

1. Nunca hagas commit en `main`. Crea una rama como `feature/descripcion-corta-en-kebab-case`.
2. Ejecuta `bash -n` y `shellcheck` en cada script que toques, y `terraform fmt` más `terraform validate` en los cambios de Terraform.
3. Haz commit de archivos concretos (sin `git add .`), con mensajes en español: `tipo(alcance): descripción`.
4. Abre un pull request contra `main`. Nadie fusiona su propio pull request.

El código y los comentarios están en inglés. La documentación está en español y los README son bilingües. Los recursos de AWS se nombran `{proyecto}-{servicio}-{propósito}`.

**¿Es tu primer pull request?** Mira la guía: [How to Contribute to an Open Source Project on GitHub](https://kcd.im/pull-request)

## Licencia

Este repositorio todavía no incluye un archivo de licencia. Hasta que el propietario agregue una, todos los derechos están reservados por defecto. Abre una incidencia si quieres reutilizar el código.

## Soporte

Responsable: [@ocastelblanco](https://github.com/ocastelblanco). Abre una [incidencia](https://github.com/ocastelblanco/moodle-development/issues) para dudas o errores.

Basado en el proyecto ACG Calidad (actualización de Moodle 4.1 a 5.x).
