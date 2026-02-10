# activation-compliance

Proyecto contiene funciones Lambda de AWS para la gestión del cumplimiento y activación de empresas.

## Funciones Lambda

### update_company_status

Función Lambda que actualiza el estado operacional de las empresas (`enterprise_enterprise`) basándose en criterios de cumplimiento.

#### Descripción

Esta función evalúa y actualiza el estado operacional de todas las empresas en la base de datos, determinando si deben estar **activas** o **inactivas** según los siguientes criterios de cumplimiento:

- **Registro completo**: `is_full_register = true`
- **KYC completado**: `is_kyc = true`
- **Propietario válido**: La empresa debe tener al menos un propietario (`OWNER_ROLE_ID = 1`) que cumpla con:
  - Usuario activo (`is_active = true`)
  - Registro completo (`is_full_register = true`)
  - KYC completado (`is_kyc = true`)
  - Relación activa con la empresa (`npe.is_active = true`)

**Una empresa solo se activa si cumple con los tres criterios simultáneamente.**

#### Características Técnicas

- **Procesamiento por lotes**: Utiliza micro-lotes de 2000 registros (`FETCH_ITERSIZE`) para optimizar el rendimiento y el uso de memoria
- **Server-side cursor**: Implementa cursores del lado del servidor para procesar grandes volúmenes de datos de manera eficiente
- **Control de timeout**: Verifica el tiempo restante antes de cada lote para evitar que la función se agote (margen de 20 segundos)
- **Actualizaciones en batch**: Agrupa las actualizaciones por estado objetivo para minimizar las operaciones de base de datos
- **Manejo de errores**: Implementa rollback automático en caso de excepciones

#### Configuración

La función requiere las siguientes variables de entorno:

- `SECRET_NAME`: Nombre del secreto en AWS Secrets Manager que contiene las credenciales de la base de datos

El secreto debe contener:
```json
{
  "host": "hostname-de-la-base-de-datos",
  "dbname": "nombre-de-la-base-de-datos",
  "username": "usuario",
  "password": "contraseña",
  "port": 5432
}
```

#### Dependencias

- `boto3`: Cliente de AWS SDK para Python (incluido en el runtime de Lambda, pero necesario para desarrollo local)
- `psycopg2-binary`: Adaptador de PostgreSQL para Python (versión precompilada, recomendada para Lambda)

**⚠️ Importante**: Para Lambda, se debe usar `psycopg2-binary` en lugar de `psycopg2` porque:
- `psycopg2` requiere compilación nativa y librerías del sistema
- `psycopg2-binary` viene precompilado y funciona directamente en Lambda

#### Instalación de Dependencias

Para desarrollo local:

```bash
cd src/lambdas/update_company_status
pip install -r requirements.txt
```

Para empaquetar para Lambda, ver la sección [Empaquetado para Deployment](#empaquetado-para-deployment).

#### Parámetros de Configuración

- `INACTIVE_STATUS_ID = 1`: ID del estado inactivo
- `ACTIVE_STATUS_ID = 2`: ID del estado activo
- `OWNER_ROLE_ID = 1`: ID del rol de propietario
- `FETCH_ITERSIZE = 2000`: Tamaño del micro-lote para procesamiento
- `TIMEOUT_MARGIN_MS = 20000`: Margen de tiempo en milisegundos antes del timeout

#### Respuesta

La función retorna un objeto JSON con la siguiente estructura:

```json
{
  "status": "SUCCESS" | "PARTIAL_TIMEOUT",
  "stats": {
    "total": 0,
    "act": 0,
    "inact": 0,
    "timeout": false
  },
  "duration": 0.0
}
```

- `status`: Estado de la ejecución (`SUCCESS` si completó, `PARTIAL_TIMEOUT` si se agotó el tiempo)
- `stats.total`: Total de empresas procesadas
- `stats.act`: Empresas actualizadas a estado activo
- `stats.inact`: Empresas actualizadas a estado inactivo
- `stats.timeout`: Indica si la función se detuvo por timeout
- `duration`: Duración de la ejecución en segundos

#### Flujo de Ejecución

1. Obtiene las credenciales de la base de datos desde AWS Secrets Manager
2. Establece conexión con PostgreSQL
3. Ejecuta una consulta que obtiene todas las empresas con sus criterios de cumplimiento
4. Procesa los resultados en micro-lotes:
   - Evalúa el estado objetivo para cada empresa
   - Identifica las empresas que requieren cambio de estado
   - Agrupa los cambios por estado objetivo (activo/inactivo)
   - Ejecuta actualizaciones en batch
5. Retorna estadísticas de la ejecución

#### Manejo de Errores

- En caso de excepciones, se realiza rollback automático de las transacciones
- Los errores se registran en CloudWatch Logs
- La función propaga la excepción para que AWS Lambda la maneje apropiadamente

#### Optimizaciones

- **List Comprehensions**: Utiliza list comprehensions de Python para procesamiento eficiente de datos
- **Actualizaciones condicionales**: Solo actualiza empresas cuyo estado actual difiere del estado objetivo
- **Procesamiento streaming**: Procesa datos en tiempo real sin cargar todo en memoria
- **Transacciones por lote**: Commits incrementales para evitar bloqueos prolongados

#### Empaquetado para Deployment

Para desplegar esta función Lambda, necesitas empaquetar las dependencias correctamente. El problema más común es con `psycopg2` que requiere compilación nativa.

**Solución recomendada: Usar `psycopg2-binary`**

1. **Instalar dependencias en un entorno limpio** (preferiblemente en un contenedor Docker con Amazon Linux 2):

```bash
# Crear directorio para el paquete
mkdir -p package
cd package

# Instalar dependencias en el directorio package
pip install -r ../requirements.txt -t .

# Copiar el código de la lambda
cp ../lambda_handler.py .

# Crear el archivo ZIP
zip -r ../lambda-deployment.zip .
```

2. **Usar Docker para empaquetar (Recomendado)**:

```bash
# Ejecutar en un contenedor con Amazon Linux 2 (mismo entorno que Lambda)
docker run --rm -v $(pwd):/var/task \
  public.ecr.aws/lambda/python:3.11 \
  /bin/bash -c "pip install -r /var/task/src/lambdas/update_company_status/requirements.txt -t /var/task/package && cp /var/task/src/lambdas/update_company_status/lambda_handler.py /var/task/package/ && cd /var/task/package && zip -r /var/task/lambda-deployment.zip ."
```

3. **Alternativa: Usar AWS Lambda Layers**

Si prefieres usar capas de Lambda, puedes crear una capa con `psycopg2-binary`:

```bash
mkdir -p layer/python
pip install psycopg2-binary -t layer/python/
cd layer
zip -r ../psycopg2-layer.zip .
```

Luego asocia esta capa a tu función Lambda.

**Notas importantes:**
- Asegúrate de empaquetar para la misma arquitectura que tu Lambda (x86_64 o arm64)
- El tamaño del paquete no debe exceder 50 MB (sin comprimir) o 250 MB (comprimido)
- Si el paquete es muy grande, considera usar Lambda Layers para las dependencias
