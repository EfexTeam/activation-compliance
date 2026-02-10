import os
import json
import logging
import psycopg2
import boto3
from datetime import datetime

# --- Configuración Global ---
logger = logging.getLogger()
logger.setLevel(logging.INFO)

session = boto3.session.Session()
secrets_client = session.client(service_name='secretsmanager')

def get_secret():
    secret_name = os.environ['SECRET_NAME']
    response = secrets_client.get_secret_value(SecretId=secret_name)
    return json.loads(response['SecretString'])

def lambda_handler(event, context):
    """
    Ejecuta el REFRESH de la Vista Materializada de PLD.
    """
    conn = None
    start_time = datetime.now()
    
    try:
        # 1. Conexión a la BD
        creds = get_secret()
        conn = psycopg2.connect(
            host=creds['host'],
            database=creds['dbname'],
            user=creds['username'],
            password=creds['password'],
            port=creds.get('port', 5432)
        )
        
        # IMPORTANTE: El REFRESH CONCURRENTLY no puede correr dentro de una transacción.
        # Ponemos el autocommit en True.
        conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)
        
        with conn.cursor() as cur:
            logger.info("Iniciando REFRESH CONCURRENTLY de la vista pld_subjects_for_screening...")
            
            # 2. Ejecución del comando
            cur.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY pld_subjects_for_screening;")
            
            logger.info("Vista refrescada exitosamente.")

        return {
            "status": "SUCCESS",
            "duration_seconds": (datetime.now() - start_time).total_seconds()
        }

    except Exception as e:
        logger.error(f"Error al refrescar la vista: {str(e)}")
        raise e
    finally:
        if conn:
            conn.close()

