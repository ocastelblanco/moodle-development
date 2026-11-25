# 11. Escalado de la infraestructura

Guía para aumentar (o vigilar) la capacidad de un Moodle de **un solo servidor**: EC2 + EBS + RDS. El escalado es **vertical**; el escalado horizontal es una fase futura (ver [Límites](#límites-y-fase-futura-escalado-horizontal)).

## Flujo manual (asistido por IA o por el operador)

Se ejecuta desde la máquina del operador con AWS CLI v2:

```bash
./scripts/09-scale-infrastructure.sh --profile mi-perfil --region us-east-1 report
./scripts/09-scale-infrastructure.sh resize-ec2 t4g.large       # 2-5 min de caída
./scripts/09-scale-infrastructure.sh resize-rds db.t4g.medium   # ventana de mantenimiento (--now: inmediato)
./scripts/09-scale-infrastructure.sh grow-ebs 50                # sin caída; solo crecer
./scripts/09-scale-infrastructure.sh enable-cloudfront-hint
```

Los recursos se descubren por nombre (`<proyecto>-<entorno>-ec2`, `-data`, `-db-*`); usa `--project` y `--env` si difieren de `moodle`/`prod`. Los comandos que modifican piden confirmación (`--yes` la omite).

1. **Diagnosticar**: `report` entrega CPU (prom./máx. a 7 y 30 días), saldo mínimo de créditos de CPU, memoria y disco (CWAgent), métricas de RDS, costo del mes (si hay permiso `ce:GetCostAndUsage`) y una recomendación.
2. **Decidir** (umbrales orientativos):

| Señal | Acción |
|-------|--------|
| CPU EC2 prom. > 70 % o créditos mínimos < 50 | Subir un escalón: t4g.small → medium → large → xlarge |
| Memoria > 85 % sostenida | Subir EC2 un escalón y re-ejecutar `scripts/05-optimize-system.sh` |
| Disco `/moodledata` > 80 % | `grow-ebs` (~+25 %) |
| CPU RDS > 70 % o memoria libre < ~150 MB | Subir RDS un escalón: db.t4g.micro → small → medium → large |
| Espacio libre RDS bajo | El autoescalado de almacenamiento de RDS (`max_allocated_storage`) ya está activo; verificar el tope |
| Muchos estáticos / ancho de banda | Activar CloudFront (`enable_cloudfront = true`) |
| 502/503 con CPU normal | Reajustar PHP-FPM (`05-optimize-system.sh`) antes de comprar hardware |
| BD cargada con RAM libre, sesiones/caché pesados | Evaluar Redis/Valkey (cambio aparte) |

3. **Aplicar** un solo escalón y observar 24-72 h.
4. Tras un resize de EC2, el script recuerda re-ejecutar `05-optimize-system.sh` (puede lanzarlo vía SSM si el script existe en la instancia) porque `pm.max_children` depende de la RAM.
5. Actualizar `terraform.tfvars` con el nuevo tamaño para evitar deriva de Terraform.

## Flujo automatizado (Terraform)

```
 CloudWatch Alarm            EventBridge            SSM Automation              SNS
 (disco > 80 %)  ───────▶  regla ALARM  ───────▶  <prefijo>-ebs-autogrow ───▶ email
                                                   (ModifyVolume + growpart
                                                    + xfs_growfs/resize2fs)

 EventBridge Scheduler ───▶ SSM Automation <prefijo>-compute-autoresize
 (semanal)                   evalúa 7 días de métricas
                               ├─ modo notify ───────────────────────────▶ SNS (recomendación)
                               └─ modo apply  → sube UN escalón (EC2: stop/modify/start;
                                  RDS: ventana de mantenimiento) ────────▶ SNS (resultado)

 AWS Budgets (50/80/100 % real, 100 % pronóstico) ─────────────────────▶ SNS
```

> **ADVERTENCIA - Actualiza `terraform.tfvars` antes del siguiente `terraform apply`.**
> Cuando el modo automatizado (`compute_autoresize_mode = "apply"`) o el autogrow de EBS cambian el tipo de instancia, la clase de RDS o el tamaño del volumen, Terraform no se entera: su estado sigue con los valores anteriores. Debes reflejar los nuevos valores en `terraform/terraform.tfvars` (`instance_type`, `db_instance_class`, `data_volume_size`) **antes** de ejecutar otro `terraform apply`. Si no lo haces, Terraform revertirá el cambio: EC2/RDS volverían al tamaño anterior (reducción con caída de servicio) y, como los volúmenes EBS **no se pueden reducir**, el `apply` fallaría en el volumen. Los mensajes SNS de la automatización incluyen este recordatorio.
>
> Nota: las variables existentes `enable_cloudwatch_alarms` y `alarm_email` **no** controlan las alarmas de escalado; estas usan `scaling_alert_emails`.

Alarmas creadas: `<prefijo>-moodledata-disk-high`, `-ec2-cpu-high`, `-ec2-cpu-credits-low`, `-rds-cpu-high`, `-rds-freeable-memory-low`, `-rds-free-storage-low`. Tópico SNS: `<prefijo>-scaling-alerts` (prefijo = `<proyecto>-<entorno>`). Tras `terraform apply`, **confirma la suscripción** desde el correo de cada destinatario.

### Variables

| Variable | Default | Descripción |
|----------|---------|-------------|
| `enable_ebs_autogrow` | `true` | Crece EBS + sistema de archivos al disparar la alarma de disco |
| `ebs_autogrow_threshold_percent` | `80` | Umbral de uso de disco |
| `ebs_autogrow_increment_percent` | `25` | Incremento por evento |
| `ebs_autogrow_max_size_gb` | `200` | Tope de tamaño |
| `enable_compute_autoresize` | `false` | Evaluación semanal de EC2/RDS |
| `compute_autoresize_mode` | `"notify"` | `notify` solo avisa; `apply` sube un escalón |
| `ec2_instance_type_ladder` | `["t4g.small","t4g.medium","t4g.large","t4g.xlarge"]` | Escalera EC2 (el último es el tope) |
| `rds_instance_class_ladder` | `["db.t4g.micro","db.t4g.small","db.t4g.medium","db.t4g.large"]` | Escalera RDS |
| `autoresize_schedule` | `cron(0 8 ? * SUN *)` | Domingo 03:00 hora Colombia (UTC-5) |
| `cpu_high_threshold_percent` | `70` | Umbral de CPU |
| `cpu_credit_low_threshold` | `50` | Umbral de créditos de CPU |
| `scaling_alert_emails` | `[]` | Correos para SNS |
| `monthly_budget_usd` | `30` | Límite de AWS Budgets |

Activación recomendada: primero `enable_compute_autoresize = true` con `compute_autoresize_mode = "notify"`; pasar a `"apply"` solo si aceptas caídas automáticas de 2-5 min (EC2) y cambios de RDS en su ventana de mantenimiento. La Elastic IP se conserva. La automatización **nunca reduce** tamaños.

## Costos y créditos AWS

- Desde el 15-jul-2025 las cuentas nuevas eligen **Free plan** o **Paid plan**. Créditos: USD 100 al registrarse + hasta USD 100 por actividades (máx. USD 200); vencen 12 meses después de crear la cuenta.
- **Free plan**: hasta 6 meses o hasta agotar créditos (lo que ocurra primero), solo un subconjunto de servicios, sin cobros hasta hacer upgrade.
- **Paid plan**: todos los servicios, pago por uso al agotar créditos; se puede fijar un límite de gasto mensual desde USD 20. No se puede volver de Paid a Free. Unirse a AWS Organizations termina los créditos.
- Sin verificar (confirmar en la consola o en https://aws.amazon.com/free/faqs/): tipos de instancia elegibles en el Free plan y qué ocurre al terminar los 6 meses sin upgrade.
- Escalar consume créditos más rápido: mantén AWS Budgets (`monthly_budget_usd`) activo y ejecuta `report` antes de subir de tamaño. Referencias de precio en el [README](../README.md#-costos-estimados).

## Rollback (reducir tamaño)

La automatización no reduce; hágalo manualmente en una ventana de baja actividad:

- **EC2**: `./scripts/09-scale-infrastructure.sh resize-ec2 t4g.medium` y re-ejecutar `05-optimize-system.sh`. Verifica antes que la RAM cubra el uso (swap/OOM).
- **RDS**: `./scripts/09-scale-infrastructure.sh resize-rds db.t4g.small` (ventana de mantenimiento) tras confirmar conexiones y memoria. Haz un snapshot previo.
- **EBS**: no se puede reducir un volumen. Hay que crear un volumen menor, copiar `/moodledata` (rsync) y reemplazarlo; hazlo solo con backup verificado.
- Actualiza `terraform.tfvars` para que coincida con el estado real.

## Límites y fase futura (escalado horizontal)

Este flujo escala **solo verticalmente en un servidor**. El escalado horizontal (ALB + EFS + Valkey + Auto Scaling Group) **no está implementado**: es una fase futura. Señales orientativas de que toca planificarla: ya estás en t4g.xlarge / db.t4g.large con CPU sostenida > 70 %, más de ~500 usuarios concurrentes, o necesitas alta disponibilidad / despliegues sin caída.

Ver también: [08-monitoring.md](08-monitoring.md), [09-maintenance.md](09-maintenance.md), skill [scale-infrastructure](../skills/scale-infrastructure/SKILL.md).
