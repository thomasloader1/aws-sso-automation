# aws-sso.ps1 — Tutorial genérico para AWS SSO

Este repositorio contiene un helper de PowerShell para trabajar con perfiles AWS SSO en Windows.

El script ayuda a:
- listar perfiles SSO configurados
- verificar el estado de autenticación
- iniciar login SSO para uno o varios perfiles
- establecer `AWS_PROFILE` en la terminal actual
- abrir un túnel local SSM a una base de datos remota

No guarda credenciales. Lee perfiles desde `%USERPROFILE%\.aws\config`.

---

## Requisitos

1. **AWS CLI v2** instalado y disponible en el `PATH`.
2. Perfiles SSO configurados en `~\.aws\config`.
3. Para `db-tunnel`: [Session Manager Plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) instalado y la terminal reiniciada después de la instalación.

### Ejemplo de `~\.aws\config`

```ini
[sso-session aws-sso]
sso_start_url = https://your-sso-start-url.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile my-dev-profile]
sso_session = aws-sso
sso_account_id = 123456789012
sso_role_name = ReadOnly
region = us-east-1
output = json

[profile my-other-profile]
sso_session = aws-sso
sso_account_id = 123456789012
sso_role_name = ReadOnly
region = us-east-1
```

Si varios perfiles comparten el mismo `sso_session`, un solo login SSO suele ser suficiente para todos.

---

## Uso

Desde la carpeta donde está el script:

```powershell
.\aws-sso.ps1 <comando> [opciones]
```

> En PowerShell usa `\.\aws-sso.ps1` o `./aws-sso.ps1` según la versión.

---

## Comandos
| Comando | Descripción |
|---------|-------------|
| `list` | Lista perfiles SSO válidos encontrados en el archivo de configuración |
| `status` | Muestra si cada perfil está autenticado, expirado o con error |
| `login` | Inicia el flujo de login SSO para perfiles seleccionados |
| `use` | Establece `AWS_PROFILE` en la sesión actual |
| `db-tunnel` | Abre un túnel local SSM a una base de datos remota |
| `db-creds` | Muestra usuario/password de RDS desde Secrets Manager |
| `s3-creds` | Muestra credenciales SSO temporales + buckets baycollections* |
| `smtp-creds` | Lista SES SMTP; por defecto pide el Secret IAM y lo convierte a password SMTP (sin rotar keys) |
| `help` | Muestra ayuda básica |

### `list`

Lista los perfiles SSO válidos encontrados en tu archivo `~\.aws\config`.

```powershell
.\aws-sso.ps1 list
```

### `status`

Verifica el estado de autenticación de cada perfil.

```powershell
.\aws-sso.ps1 status
```

Entrega un estado por perfil como `ok`, `expired` o `error`.

### `login`

Realiza el flujo de login SSO en el navegador.

```powershell
# Login usando el perfil por defecto del script
.\aws-sso.ps1 login

# Login para uno o varios perfiles separados por comas
.\aws-sso.ps1 login -Profiles my-dev-profile,my-other-profile

# Login para todos los perfiles SSO encontrados
.\aws-sso.ps1 login -All
```

El script agrupa los perfiles por `sso_session` para evitar solicitar múltiples logins innecesarios.

### `use`

Establece `AWS_PROFILE` **solo en la sesión actual** de PowerShell.

```powershell
# Dot-source para que el cambio persista en esta terminal
. .\aws-sso.ps1 use my-dev-profile
```

Si lo ejecutas sin el punto inicial (`. `), el script te mostrará cómo fijar la variable manualmente.

### `db-tunnel`

Abre un túnel local usando AWS Systems Manager Session Manager hacia un host remoto configurado en el script o en `aws-sso.targets.json`.

```powershell
# Túnel por defecto
.\aws-sso.ps1 db-tunnel

# Forzar engine y puerto local
.\aws-sso.ps1 db-tunnel -DbEngine postgres -LocalPort 5432

# Usar otro perfil AWS y puerto local
.\aws-sso.ps1 db-tunnel -DbEngine postgres -LocalPort 15432 -AwsProfile my-dev-profile
```

Si el perfil no está autenticado, el script intenta `aws sso login` automáticamente.

---

## Flujo recomendado

1. Ejecuta login SSO para los perfiles que vas a usar:

```powershell
.\aws-sso.ps1 login -All
```

2. Verifica el estado:

```powershell
.\aws-sso.ps1 status
```

3. Selecciona el perfil activo en tu terminal:

```powershell
. .\aws-sso.ps1 use my-dev-profile
```

4. Si necesitas acceso a una base de datos privada, abre el túnel SSM:

```powershell
.\aws-sso.ps1 db-tunnel -DbEngine postgres -LocalPort 5432
```

5. Conecta tu cliente SQL a `localhost:<LocalPort>`.

---

## Parámetros globales útiles

| Parámetro | Default | Aplica a |
|-----------|---------|----------|
| `-Profiles` | — | `login` |
| `-All` | off | `login` |
| `-AwsProfile` | Perfil por defecto del script | `db-tunnel` (y login si no pasas perfiles) |
| `-DbEngine` | `postgres` | `db-tunnel` (`postgres` \| `sqlserver`) |
| `-LocalPort` | `5432` | `db-tunnel` |
| `-BastionId` | Valor definido en `aws-sso.targets.json` o en el script | `db-tunnel` |

---

## Solución de problemas

- `AWS CLI` no encontrado: instala AWS CLI v2 y reinicia la terminal.
- `Session Manager Plugin` faltante: instala el plugin y vuelve a abrir PowerShell.
- `Token has expired`: vuelve a ejecutar `login` para el perfil afectado.
- `aws-sso.ps1` no se reconoce: usa `\.\aws-sso.ps1` desde la carpeta donde está el script.
- Si `use` no mantiene `AWS_PROFILE`, ejecuta el comando con dot-source:

```powershell
. .\aws-sso.ps1 use my-dev-profile
```
- Si el túnel SSM abre pero no se conecta, mantén la ventana abierta y verifica el puerto local y el perfil AWS autenticado.

---

## Notas finales

- El helper está diseñado para facilitar la autenticación SSO y el acceso SSM desde PowerShell.
- Las credenciales de base de datos no se administran aquí.
- Ajusta los nombres de perfil, rutas y parámetros según tu entorno AWS.
