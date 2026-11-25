# 10. Certificados automáticos de finalización de curso

Guía para administradores y docentes. Plataforma: Moodle 5.3 LTS sobre Amazon Linux 2023 (PHP 8.4) con Amazon RDS for MariaDB 11.8.

Objetivo: cuando un estudiante **aprueba** un curso (curso finalizado **y** nota total ≥ nota mínima, 70 % por defecto), Moodle genera un certificado en PDF, se lo envía por correo (Amazon SES) y lo deja disponible para descarga. Cualquier persona puede verificarlo con el código o el QR.

Plugins utilizados (Moodle HQ):
- **tool_certificate** (*Workplace certificate manager*): diseñador de plantillas, almacenamiento de certificados emitidos y página de verificación.
- **mod_coursecertificate** (*Workplace course certificate*): actividad de curso con envío automático.

---

## 1. Arquitectura

```
 ┌──────────────┐   completa actividades   ┌──────────────────────────────┐
 │  Estudiante  │ ───────────────────────▶ │ Moodle: finalización + notas │
 └──────────────┘                          └──────────────┬───────────────┘
                                                          │ (cada minuto)
                                                          ▼
                                           ┌──────────────────────────────┐
                                           │ cron  (/etc/cron.d/moodle)   │
                                           │  admin/cli/cron.php          │
                                           └──────────────┬───────────────┘
                                                          ▼
                    ┌─────────────────────────────────────────────────────────┐
                    │ Tarea programada "Issue course certificates"            │
                    │ \mod_coursecertificate\task\issue_certificates_task     │
                    │  ¿curso finalizado?  Y  ¿total del curso ≥ mínimo?      │
                    └───────────────┬─────────────────────────────────────────┘
                                    │ sí
                                    ▼
                    ┌───────────────────────────────┐
                    │ tool_certificate genera PDF   │
                    │ (código único + QR)           │
                    │ guardado en /moodledata       │
                    │ (filedir)  + registro en RDS  │
                    └───────┬───────────────┬───────┘
                            │               │
                            ▼               ▼
             ┌─────────────────────┐   ┌─────────────────────────────┐
             │ Amazon SES (SMTP    │   │ Descarga: página de la      │
             │ TLS 587) → correo   │   │ actividad y "Mis            │
             │ con PDF adjunto     │   │ certificados" del perfil    │
             └─────────────────────┘   └─────────────────────────────┘

 Tercero (empleador, universidad) ── escanea QR / ingresa código ──▶
   https://<dominio>/admin/tool/certificate/index.php  (pública, sin login)
   → muestra: Válido · nombre · curso · fecha de emisión
```

Puntos clave:
- Sin **cron cada minuto** no se emite nada.
- El criterio de aprobación se implementa con las **restricciones de acceso** de la actividad "Certificado de curso".
- Las credenciales SMTP viven en **SSM Parameter Store** (SecureString), nunca en el código.

---

## 2. Instalación (administrador de servidor)

### 2.1 Requisitos previos

- Moodle 5.3 instalado con `scripts/03-install-moodle.sh` (rama `MOODLE_503_STABLE`).
- Extensión PHP `sodium` (`php8.4-sodium`).
- Amazon SES: dominio verificado, cuenta **fuera del sandbox**, credenciales SMTP creadas.
- Parámetros SSM, por ejemplo `/acg/ses/smtp-user` y `/acg/ses/smtp-password` (SecureString), y el rol IAM de la EC2 con permiso `ssm:GetParameter` sobre ellos.
- Alternativa automatizada: `terraform/ses.tf` crea identidad, DNS, credenciales, parámetros SSM y permisos (ver 2.5).

### 2.2 Verificar compatibilidad de los plugins

> **Riesgo conocido:** al momento de escribir esta guía, el directorio de plugins lista `tool_certificate` solo hasta Moodle 5.2. Antes de instalar, revise https://moodle.org/plugins/tool_certificate y https://moodle.org/plugins/mod_coursecertificate y confirme una versión para 5.3. Si no existe, pruebe primero en un entorno de staging o use el **plan B** (sección 8).

### 2.3 Variables en `/root/moodle-config.env`

```bash
CERT_MIN_GRADE_PERCENT=70
CERT_PUBLIC_VERIFICATION=true
CERT_PLUGIN_TOOLCERT_VERSION=""      # tag o rama git; vacío = rama por defecto
CERT_PLUGIN_COURSECERT_VERSION=""
SMTP_HOST="email-smtp.us-east-1.amazonaws.com:587"
SMTP_USER_SSM_PARAM="/acg/ses/smtp-user"
SMTP_PASS_SSM_PARAM="/acg/ses/smtp-password"
NOREPLY_ADDRESS="noreply@acg.edu.co"
```

### 2.4 Ejecutar el script

```bash
sudo scripts/08-setup-certificates.sh
```

El script es idempotente (puede ejecutarse varias veces). Instala o actualiza los plugins con git, ejecuta la actualización de Moodle, configura SMTP con SES, activa el seguimiento de finalización y las restricciones de acceso, habilita la verificación pública y comprueba la tarea programada. Registro: `/var/log/moodle-certificates-setup.log` (no contiene secretos).

### 2.5 Credenciales SMTP con Terraform (`ses.tf`)

`terraform/ses.tf` (opcional, `enable_ses_smtp = true`) reemplaza el proceso manual de `aws-email-system/AWS_EMAIL_SYSTEM.md`:

- Identidad de dominio SES (`ses_domain`, por defecto `domain_name`) con Easy DKIM RSA 2048 y MAIL FROM personalizado opcional (`ses_mail_from_subdomain = "mail"` → `mail.<dominio>`).
- Registros DNS en Route 53 si `route53_zone_id` está definido: 3 CNAME DKIM, DMARC (`ses_dmarc_policy`, por defecto `p=quarantine`, `rua` opcional con `ses_dmarc_rua_email`), MX + TXT del MAIL FROM y, solo si `ses_manage_spf = true`, el SPF raíz. **SPF está desactivado por defecto**: Route 53 guarda todos los TXT de un nombre en un solo registro; si ya existe un TXT raíz, agregue `include:amazonses.com` a mano. Sin zona, los registros salen en `terraform output ses_dns_records_manual`.
- Usuario IAM `<proyecto>-<entorno>-ses-smtp` con permiso mínimo (`ses:SendRawEmail`/`ses:SendEmail` solo sobre la identidad y el configuration set, y solo con remitente `*@<dominio>`), su access key y la contraseña SMTP derivada.
- Parámetros SSM `SecureString` (por defecto `/<proyecto>/<entorno>/ses/smtp-user` y `.../smtp-password`, clave `aws/ssm` o `kms_key_id`) y permiso `ssm:GetParameter` del rol de la EC2 solo sobre esos dos parámetros.
- Configuration set `<proyecto>-<entorno>-ses` (asignado como predeterminado de la identidad, porque Moodle no envía la cabecera `X-SES-CONFIGURATION-SET`) con métricas de reputación y eventos BOUNCE/COMPLAINT/REJECT hacia el tópico SNS `<proyecto>-<entorno>-ses-events` (suscriptores: `scaling_alert_emails`), más alarmas de CloudWatch sobre la tasa de rebotes (> 5 %) y de quejas (> 0,1 %) de la cuenta.
- Lista de supresión **a nivel de cuenta** (BOUNCE, COMPLAINT) con `ses_enable_account_suppression` (por defecto `true`; afecta a todos los remitentes SES de la cuenta y región).

> **Secretos en el estado de Terraform:** la contraseña SMTP y la clave secreta IAM quedan en `terraform.tfstate`. Antes de activarlo en producción configure el backend S3 cifrado (bloque `backend "s3"` comentado en `terraform/main.tf`) y nunca suba el estado a git.

Valores para `/root/moodle-config.env` (las salidas nunca incluyen la contraseña):

```bash
cd terraform
echo "SMTP_HOST=\"$(terraform output -raw ses_smtp_host):587\""
echo "SMTP_USER_SSM_PARAM=\"$(terraform output -raw ses_smtp_user_ssm_param)\""
echo "SMTP_PASS_SSM_PARAM=\"$(terraform output -raw ses_smtp_pass_ssm_param)\""
echo "NOREPLY_ADDRESS=\"$(terraform output -raw ses_noreply_address)\""
terraform output ses_identity_status   # tras propagar DNS: terraform refresh
```

**Rotación de credenciales:**

1. Incrementar `ses_smtp_key_version` en `terraform.tfvars` (p. ej. `"1"` → `"2"`).
2. `terraform apply`: crea la nueva access key, actualiza ambos parámetros SSM y elimina la anterior. Desde ese momento Moodle no puede enviar correo hasta el paso 3.
3. Inmediatamente, en la EC2: `sudo scripts/08-setup-certificates.sh` (o solo el bloque SMTP de `scripts/03-install-moodle.sh`) para recargar las credenciales desde SSM.
4. Probar: *Administración del sitio > Servidor > Correo > Probar configuración de correo saliente*.

**Sigue siendo manual:** solicitar el acceso de producción de SES (salir del sandbox, 24-48 h). Verifique con `aws sesv2 get-account` → `ProductionAccessEnabled: true`.

---

## 3. Diseño de la plantilla (administrador del sitio)

1. Ir a *Administración del sitio > Certificados > Gestionar plantillas de certificado > Nueva plantilla*.
2. Nombre: p. ej. "Certificado institucional de aprobación". Compartir con las categorías de curso que la usarán.
3. Página: A4 o Carta horizontal. Subir imagen de fondo (≤ 1 MB) con logos y firmas.
4. Agregar elementos:

| Elemento | Configuración |
|----------|---------------|
| Nombre completo | Campo de usuario → Nombre completo |
| Cédula / documento | Campo de usuario → *Número de ID* (`idnumber`) o campo de perfil personalizado (p. ej. `cedula`) |
| Nombre del curso | Campo de curso → Nombre completo |
| Fecha de finalización | Fecha de finalización del curso |
| Nota | Calificación del curso |
| Código de verificación | Elemento *Código* |
| Código QR | Elemento *Código QR* (enlaza a la página de verificación) |

5. Usar *Vista previa* para revisar el PDF con datos de ejemplo.

> Si usará la cédula, cree el campo en *Administración del sitio > Usuarios > Campos de perfil de usuario* y asegúrese de que todos los estudiantes lo tengan diligenciado.

---

## 4. Configuración de un curso (docente / gestor)

1. **Activar finalización:** *Configuración del curso > Seguimiento de finalización > Habilitar = Sí*.
2. **Criterios de finalización:** *Más > Finalización del curso*. Ejemplos: todas las actividades calificables completadas, o "Calificación del curso" mínima.
3. **Libro de calificaciones:** confirme que el *Total del curso* agrega correctamente las actividades. Opcional: definir *Calificación para aprobar*.
4. **Agregar la actividad** *Certificado de curso* (Course certificate):
   - Plantilla: la institucional.
   - **Envío automático: Sí** (esto dispara el correo con el PDF).
5. **Restricciones de acceso** de esa actividad (deben cumplirse **todas**):
   - *Finalización del curso*: debe estar marcado como completado.
   - *Calificación*: *Total del curso* **≥ 70 %** (o el valor acordado; en escala 0–5, 3.0 equivale a 60 %).
6. Guardar. Desde ese momento, en el siguiente ciclo de cron, cada estudiante que cumpla ambas condiciones recibe su certificado.

---

## 5. ¿Cómo obtiene el estudiante su certificado?

- **Correo electrónico:** recibe un mensaje desde `noreply@<dominio>` con el PDF adjunto.
- **Página de la actividad:** entrando al curso, en la actividad "Certificado de curso" → botón para ver/descargar.
- **Perfil:** *Mi perfil > Mis certificados* lista todos sus certificados de todos los cursos.

Si el estudiante aún no cumple las condiciones, verá la actividad bloqueada (o no la verá si se ocultaron las restricciones).

---

## 6. Verificación pública

- Cada certificado tiene un **código único** y un **QR**.
- Un tercero escanea el QR o abre `https://<dominio>/admin/tool/certificate/index.php` e ingresa el código.
- La página muestra si el certificado es **válido**, nombre del titular, curso y fecha de emisión. No muestra correo, cédula ni notas.
- Funciona sin iniciar sesión si `CERT_PUBLIC_VERIFICATION=true` y **no** está activado `forcelogin`.

Prueba: abra el enlace del QR en una ventana privada del navegador.

---

## 7. Validación end-to-end

1. *Administración del sitio > Servidor > Correo electrónico > Probar configuración de correo saliente* → debe llegar el correo.
2. Cree un estudiante de prueba, matricúlelo, complete las actividades con nota ≥ mínimo.
3. Fuerce la tarea en el servidor:
   ```bash
   sudo -u apache php /var/www/html/moodle/admin/cli/scheduled_task.php \
     --execute='\mod_coursecertificate\task\issue_certificates_task'
   ```
4. Verifique: correo recibido con PDF, certificado en "Mis certificados", QR válido en ventana privada.
5. Repita con un estudiante con nota inferior al mínimo: **no** debe recibir certificado.

---

## 8. Plan B: mod_customcert

Si `tool_certificate` no es compatible con 5.3, use **mod_customcert 5.3.5 o superior** (soporta 5.3):
- Por defecto emite el certificado **solo cuando el estudiante abre la actividad**. Para emisión automática:
  - En cada actividad: *Enviar por correo a estudiantes = Sí*.
  - Habilitar la tarea programada `\mod_customcert\task\issue_certificates_task`.
- Mismas restricciones de acceso (finalización + calificación).
- Incluye elemento QR y página de verificación propia.
- Nota: Moodle 6.0 elimina la API legacy de elementos de mod_customcert; habrá que actualizar el plugin al migrar.

---

## 9. Preguntas frecuentes

**¿Se puede reemitir un certificado?** Sí. Un gestor puede revocar el emitido desde la página de la actividad; la tarea lo volverá a emitir si el estudiante sigue cumpliendo las condiciones.

**¿Qué pasa si el docente cambia una nota después de emitido?** El certificado ya emitido no se modifica. Si debe corregirse, revóquelo y deje que se emita de nuevo.

**¿Cuánto tarda en llegar?** Normalmente pocos minutos: depende del cron (cada minuto), del cálculo de finalización (tarea `\core\task\completion_regular_task`) y de la frecuencia de la tarea de certificados.

**¿Se puede usar una escala 0–5?** Sí. La restricción de calificación es porcentual: 3.0/5.0 = 60 %, 3.5/5.0 = 70 %.

**¿Los certificados se pierden al actualizar Moodle?** No. Se guardan en la base de datos y en `/moodledata` (incluido en los respaldos de `06-setup-backups.sh`).

**¿Puedo descargar todos los certificados de un curso?** El gestor puede ver la lista de emitidos en la actividad; la descarga masiva no es parte de este alcance.

---

## 10. Solución de problemas

| Síntoma | Causa probable / acción |
|---------|-------------------------|
| No se emite ningún certificado | Cron detenido (`cat /etc/cron.d/moodle`), tarea deshabilitada o con errores (*Servidor > Tareas > Registros de tareas*), estudiante no cumple ambas condiciones. |
| El curso no aparece como finalizado | Criterios mal definidos o la tarea de finalización aún no ha corrido. Revise *Informes > Finalización del curso*. |
| Se emite pero no llega el correo | *Envío automático* desactivado; SES en sandbox; `noreplyaddress` no verificado en SES; `$CFG->noemailever` en `config.php`; revisar rebotes en la consola de SES. |
| La condición de nota nunca se cumple | Total del curso oculto, bloqueado o sin recalcular; escala distinta a la esperada. |
| La verificación pide iniciar sesión | `forcelogin` activo o la capacidad `tool/certificate:verify` no está permitida para el rol de invitado / no autenticado. |
| Falta la cédula en el PDF | Nombre corto del campo de perfil incorrecto o campo vacío para el usuario. |
| Error al actualizar plugins | Versión del plugin incompatible con 5.3 → sección 2.2 / plan B. |

---

## 11. Seguridad

- La verificación pública expone solo nombre, curso, fecha y estado. No agregue datos sensibles a la salida pública.
- Credenciales SMTP en SSM Parameter Store (SecureString); el script nunca las imprime.
- Revise capacidades: `tool/certificate:verify` solo para invitado/no autenticado (si se requiere verificación pública); `tool/certificate:manage`, `issue` y `viewallcertificates` solo para gestores; `mod/coursecertificate:receive` solo para estudiantes.
- Los certificados contienen datos personales (cédula): informe a los estudiantes en la política de tratamiento de datos (Ley 1581 de 2012).

---

## 12. Ciclo de vida y mantenimiento

- Actualice `tool_certificate` y `mod_coursecertificate` **junto con Moodle**: ante cada actualización menor/mayor de core, vuelva a ejecutar `scripts/08-setup-certificates.sh` (con los tags adecuados en `CERT_PLUGIN_*_VERSION`) antes o en la misma ventana de mantenimiento.
- Moodle 5.3 LTS: soporte general hasta ~oct-2027 y de seguridad hasta ~oct-2029.
- **Moodle 6.0:** traerá cambios de API (entre ellos la eliminación de la API legacy de elementos de mod_customcert). Antes de migrar, confirme versiones compatibles de los plugins de certificados en moodle.org/plugins y pruebe en staging.
