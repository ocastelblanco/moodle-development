# Historial de cambios

Todos los cambios relevantes de este proyecto se documentan en este archivo.

El formato sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y el proyecto usa [Versionado Semántico](https://semver.org/lang/es/).

Para el detalle de cada cambio, consulta los [pull requests](https://github.com/ocastelblanco/moodle-development/pulls).

## [2.0.0] - 2026-11-25

### Cambiado

- **Moodle 5.3 LTS:** el stack pasa de Moodle 5.1 a 5.3 LTS (rama `MOODLE_503_STABLE`), con soporte de seguridad hasta ~oct 2029.
- **PHP 8.4:** paquetes `php8.4-*` de Amazon Linux 2023 (mínimo de Moodle 5.3: 8.3; PHP 8.5 no está soportado). Se fija `max_input_vars = 5000`.
- **RDS MariaDB 11.8 (LTS):** Moodle 5.3 exige MariaDB >= 11.4, así que 10.11 deja de ser válida. El cliente en EC2 pasa a `mariadb1011-client-utils` y los dumps usan `mariadb-dump`.
- **Comprobaciones previas** en `03-install-moodle.sh`: versión de PHP, extensión `sodium`, `max_input_vars` y versión del servidor MariaDB.
- **Métricas de CloudWatch:** el agente publica ahora en el namespace `CWAgent` (antes `Moodle/EC2`) con las dimensiones `InstanceId` y `path`. Los paneles o alarmas creados fuera del repo deben actualizarse.
- **Terraform:** `required_version` sube a `>= 1.4`.
- **README bilingüe:** `README.md` (inglés) y `README.es.md` (español), con el inicio rápido corregido y el detalle técnico en `docs/`.

### Añadido

- **Skill `setup-certificates`**, script `08-setup-certificates.sh` y guía `docs/10-certificates.md`: certificados de curso automáticos (`mod_coursecertificate` + `tool_certificate`), emitidos al finalizar el curso y alcanzar la nota mínima, enviados por correo en PDF con Amazon SES y verificables públicamente por código o QR.
- **Skill `scale-infrastructure`**, script `09-scale-infrastructure.sh` y guía `docs/11-scaling.md`: escalado vertical manual asistido (`report`, `resize-ec2`, `resize-rds`, `grow-ebs`).
- **Escalado automático** (`terraform/scaling.tf`): crecimiento automático del EBS de `/moodledata`, revisión semanal de EC2/RDS en modo `notify` o `apply`, alarmas, topic SNS y AWS Budgets.
- **Credenciales SMTP con Terraform** (`terraform/ses.tf`, opcional con `enable_ses_smtp`): identidad SES con DKIM, usuario IAM de mínimo privilegio, contraseña SMTP en SSM Parameter Store como `SecureString`, rotación con `ses_smtp_key_version`, eventos de rebote y queja a SNS y alarmas de reputación.
- **Matriz de versiones y soporte** y sección de ciclo de vida en `docs/09-maintenance.md`, con la ruta de actualización desde Moodle 4.4 y desde 5.1.
- **Monitoreo de certificados:** comprobación de la tarea programada `\mod_coursecertificate\task\issue_certificates_task` y alarmas de rebotes de SES.
- **Licencia Apache 2.0** (`LICENSE`).
- Documentación del nuevo modelo de **free tier de AWS** (créditos de hasta USD 200 por un máximo de 6 meses).

### Corregido

- Rama de Moodle errónea `MOODLE_51_STABLE` (las ramas desde la 5.0 son `MOODLE_500_STABLE`, `MOODLE_501_STABLE`, etc.).
- Error de sintaxis en `terraform/outputs.tf` que impedía ejecutar `terraform validate`.
- Frontmatter YAML inválido en las 11 skills: la descripción con `Triggers: "..."` sin comillas rompía un parser estricto. Ahora usa un bloque `description: >-` y todas validan con `quick_validate.py`.
- `03-install-moodle.sh` pasaba el usuario y la contraseña SMTP por la línea de comandos, visibles en la lista de procesos. Ahora los entrega a Moodle por STDIN.
- Rutas y enlaces del README que apuntaban a archivos inexistentes (`deploy-moodle/skills/`, `skills/README.md`).

### Notas

- Nada de esta versión se ha ejecutado contra una cuenta real de AWS. Los scripts y Terraform pasan `bash -n`, `shellcheck` y `terraform validate`; falta probar `terraform plan` y los runbooks de SSM Automation en una cuenta de pruebas.
- `tool_certificate` figura en el directorio de plugins de Moodle hasta la 5.2. Comprueba su compatibilidad con 5.3 antes de instalar; la skill describe un plan B con `mod_customcert`.

## [1.1.0] - 2026-02-11

### Cambiado

- **Moodle 5.1 `/public`:** documentación actualizada a la nueva estructura de directorios. El DocumentRoot de Apache debe apuntar a `/var/www/html/moodle/public`.
- **PHP 8.2+:** requisitos actualizados (mínimo 8.2.0; soportadas 8.2, 8.3 y 8.4).
- **Requisitos de base de datos:** PostgreSQL 15+, MySQL 8.4+, MariaDB 10.11+.

### Añadido

- Documentación del **Routing Engine** de Moodle 5.1.
- Notas sobre la **relocación de plugins** tras actualizar a 5.1.

## [1.0.0] - 2026-02-02

### Añadido

- Estructura inicial de skills para agentes de IA.
- Terraform para la infraestructura completa (EC2, RDS, EBS, CloudFront, CloudWatch).
- Scripts de despliegue automatizado (01 a 07).
- Optimización de PHP-FPM según la memoria disponible.
- SSL automático con Let's Encrypt.
- Sistema de backups automatizado.
- Monitoreo con CloudWatch.
- Documentación completa.

[2.0.0]: https://github.com/ocastelblanco/moodle-development/pull/1
[1.1.0]: https://github.com/ocastelblanco/moodle-development/commit/a7793dc
[1.0.0]: https://github.com/ocastelblanco/moodle-development/commit/b55f224
