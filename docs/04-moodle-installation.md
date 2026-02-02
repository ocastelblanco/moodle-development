# Instalación de Moodle 5.1

Guía completa para instalar Moodle 5.1 en el servidor configurado.

## 📋 Prerequisitos

Antes de instalar Moodle, asegúrate de haber completado:

- ✅ [Infraestructura provisionada](03-ec2-configuration.md)
- ✅ [Servidor configurado](03-ec2-configuration.md#setup-server)
- ✅ LAMP stack instalado (Apache, PHP 8.4, MariaDB client)
- ✅ Base de datos RDS creada y accesible

## 🚀 Instalación Automatizada

### Script Recomendado

```bash
# Conectar al servidor
ssh -i ~/.ssh/your-key.pem ec2-user@your-elastic-ip

# Ejecutar script de instalación
sudo /path/to/skills/scripts/03-install-moodle.sh
```

El script automatiza todo el proceso descrito abajo.

## 📖 Instalación Manual

Si prefieres instalar manualmente o entender el proceso:

### 1. Descargar Moodle

```bash
# Navegar al directorio web
cd /var/www/html

# Clonar Moodle 5.1 desde Git
sudo git clone --depth=1 --branch MOODLE_51_STABLE \
    https://github.com/moodle/moodle.git moodle

# Verificar versión
cd moodle
grep '$release' version.php
```

**Alternativa:** Descargar desde moodle.org
```bash
cd /tmp
wget https://download.moodle.org/download.php/direct/stable51/moodle-latest-51.tgz
tar -xzf moodle-latest-51.tgz
sudo mv moodle /var/www/html/
```

### 2. Crear Directorio de Datos

```bash
# Crear moodledata (fuera de web root por seguridad)
sudo mkdir -p /moodledata

# Crear subdirectorios
sudo mkdir -p /moodledata/{cache,localcache,sessions,temp,repository,backup}

# Configurar permisos
sudo chown -R apache:apache /moodledata
sudo chmod -R 770 /moodledata
```

### 3. Configurar SELinux

```bash
# Permitir conexiones de red (para RDS)
sudo setsebool -P httpd_can_network_connect 1
sudo setsebool -P httpd_can_network_connect_db 1

# Configurar contexto SELinux para moodledata
sudo semanage fcontext -a -t httpd_sys_rw_content_t "/moodledata(/.*)?"
sudo restorecon -Rv /moodledata
```

### 4. Crear config.php

```bash
sudo vim /var/www/html/moodle/config.php
```

**Contenido del archivo:**

```php
<?php  // Moodle configuration file
unset($CFG);
global $CFG;
$CFG = new stdClass();

// Database configuration
$CFG->dbtype    = 'mariadb';
$CFG->dblibrary = 'native';
$CFG->dbhost    = 'your-rds-endpoint.rds.amazonaws.com';
$CFG->dbname    = 'moodle';
$CFG->dbuser    = 'moodleadmin';
$CFG->dbpass    = 'your-secure-password';
$CFG->prefix    = 'mdl_';
$CFG->dboptions = array(
    'dbpersist' => 0,
    'dbport' => 3306,
    'dbsocket' => '',
    'dbcollation' => 'utf8mb4_unicode_ci',
);

// Site configuration
$CFG->wwwroot   = 'https://your-domain.com';
$CFG->dataroot  = '/moodledata';
$CFG->admin     = 'admin';
$CFG->directorypermissions = 0770;

// Performance and caching
$CFG->cachedir = '/moodledata/cache';
$CFG->localcachedir = '/moodledata/localcache';
$CFG->tempdir = '/moodledata/temp';

// Session handling (database recommended for single server)
$CFG->session_handler_class = '\core\session\database';
$CFG->session_database_acquire_lock_timeout = 120;

// Performance settings
$CFG->enablecaching = true;
$CFG->cachejs = true;
$CFG->yuicomboloading = true;

// Disable theme designer mode (IMPORTANT for production)
$CFG->themedesignermode = false;

// Password salt (generate with: openssl rand -hex 32)
$CFG->passwordsaltmain = 'your-random-salt-here';

require_once(__DIR__ . '/lib/setup.php');
```

**Configurar permisos:**
```bash
sudo chown apache:apache /var/www/html/moodle/config.php
sudo chmod 640 /var/www/html/moodle/config.php
```

### 5. Configurar Permisos

```bash
# Permisos para el código de Moodle
sudo chown -R apache:apache /var/www/html/moodle
sudo chmod -R 755 /var/www/html/moodle

# Permisos para moodledata
sudo chown -R apache:apache /moodledata
sudo chmod -R 770 /moodledata
```

### 6. Ejecutar Instalador CLI

```bash
# Ejecutar instalador de base de datos
sudo -u apache /usr/bin/php /var/www/html/moodle/admin/cli/install_database.php \
    --lang=en \
    --adminuser=admin \
    --adminpass=YourSecurePassword123! \
    --adminemail=admin@yourdomain.com \
    --fullname="My Moodle Site" \
    --shortname="Moodle" \
    --summary="Learning Management System" \
    --agree-license
```

**Parámetros:**
- `--lang`: Idioma (en, es, fr, de, etc.)
- `--adminuser`: Usuario administrador
- `--adminpass`: Contraseña (mínimo 8 caracteres)
- `--adminemail`: Email del administrador
- `--fullname`: Nombre completo del sitio
- `--shortname`: Nombre corto
- `--summary`: Descripción
- `--agree-license`: Acepta la licencia GPL

## ⚙️ Configuración Post-Instalación

### 1. Configurar Cron

El cron de Moodle debe ejecutarse cada minuto:

```bash
# Crear archivo de cron
sudo vim /etc/cron.d/moodle
```

```cron
# Moodle scheduled tasks
* * * * * apache /usr/bin/php /var/www/html/moodle/admin/cli/cron.php > /dev/null 2>&1
```

```bash
# Asignar permisos
sudo chmod 644 /etc/cron.d/moodle

# Probar cron manualmente
sudo -u apache /usr/bin/php /var/www/html/moodle/admin/cli/cron.php
```

### 2. Configurar Virtual Host Apache

Ver [06-ssl-configuration.md](06-ssl-configuration.md) para configuración completa.

Básico:
```apache
<VirtualHost *:80>
    ServerName yourdomain.com
    DocumentRoot /var/www/html/moodle

    <Directory /var/www/html/moodle>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php-fpm/www.sock|fcgi://localhost"
    </FilesMatch>
</VirtualHost>
```

### 3. Reiniciar Servicios

```bash
sudo systemctl restart php-fpm
sudo systemctl restart httpd
```

## ✅ Verificación

### 1. Verificar Instalación

```bash
# Verificar archivos de Moodle
ls -l /var/www/html/moodle/version.php

# Verificar moodledata
ls -l /moodledata/

# Verificar permisos
sudo -u apache touch /moodledata/test.txt && rm /moodledata/test.txt
```

### 2. Acceder a Moodle

```
http://your-domain.com
```

Deberías ver la página de inicio de Moodle.

### 3. Acceder al Admin

```
http://your-domain.com/admin
```

Login con:
- Usuario: admin (o el que configuraste)
- Password: Tu password

### 4. Verificar Estado del Sistema

En Moodle:
1. Ir a: **Site administration → Server → Environment**
2. Verificar que todos los requisitos estén OK
3. Ir a: **Site administration → Notifications**
4. Completar cualquier actualización pendiente

## 🔧 Configuraciones Recomendadas

### Settings del Sitio

**Site administration → Appearance → Themes → Theme settings**
```
Theme: Boost (default) o Boost Union (mejorado)
Allow user themes: No
Allow category themes: No
Allow course themes: No
```

**Site administration → Security → Site policies**
```
Password policy: Enabled
Password length: 8 minimum
Require digits: Yes
Require lowercase: Yes
Require uppercase: Yes
Require special characters: Yes
```

**Site administration → Users → Permissions → User policies**
```
Allow guest access: No (generalmente)
Default role for all users: Student
```

### Performance Settings

**Site administration → Server → Performance**
```
Theme designer mode: OFF (IMPORTANTE)
Cache JavaScript: ON
Cache templates: ON
String cache: ON
```

**Site administration → Development → Debugging**
```
Debug messages: NONE (producción)
Display debug messages: No
Performance info: No
```

### Email Settings

**Site administration → Server → Email → Outgoing mail configuration**
```
SMTP hosts: (tu servidor SMTP)
SMTP security: TLS
SMTP username: tu-email@domain.com
SMTP password: tu-password
```

## 🚨 Problemas Comunes

### Error: Could not connect to database

**Causa:** Credenciales incorrectas o RDS no accesible

**Solución:**
```bash
# Verificar conexión
mysql -h your-rds-endpoint -u moodleadmin -p

# Verificar security group permite 3306 desde EC2
```

### Error: Permission denied writing to dataroot

**Causa:** Permisos incorrectos en /moodledata

**Solución:**
```bash
sudo chown -R apache:apache /moodledata
sudo chmod -R 770 /moodledata

# SELinux
sudo setsebool -P httpd_unified 1
sudo restorecon -Rv /moodledata
```

### Warning: Cron not running

**Causa:** Cron no configurado o no ejecutándose

**Solución:**
```bash
# Verificar cron configurado
ls -l /etc/cron.d/moodle

# Ejecutar manualmente
sudo -u apache /usr/bin/php /var/www/html/moodle/admin/cli/cron.php

# Ver logs
sudo tail -f /var/log/cron
```

### Error: Site is not HTTPS

**Causa:** $CFG->wwwroot usa http en lugar de https

**Solución:**
```bash
# Editar config.php
sudo vim /var/www/html/moodle/config.php

# Cambiar:
$CFG->wwwroot = 'https://your-domain.com';  // no http
```

## 📝 Comandos Útiles

```bash
# Purge all caches
sudo -u apache php admin/cli/purge_caches.php

# Run cron manually
sudo -u apache php admin/cli/cron.php

# Check for updates
sudo -u apache php admin/cli/check_database_schema.php

# Run database upgrade
sudo -u apache php admin/cli/upgrade.php --non-interactive

# Fix permissions
sudo chown -R apache:apache /var/www/html/moodle /moodledata
sudo chmod -R 755 /var/www/html/moodle
sudo chmod -R 770 /moodledata
```

## ✅ Next Steps

1. **Configurar SSL:** [06-ssl-configuration.md](06-ssl-configuration.md)
2. **Optimizar Sistema:** [05-optimization.md](05-optimization.md)
3. **Configurar Backups:** [07-backups.md](07-backups.md)
4. **Personalizar Tema y Apariencia**
5. **Crear Categorías y Cursos**
6. **Configurar Autenticación de Usuarios**

---

**Fecha:** 2026-02-02
**Versión:** 1.0.0
