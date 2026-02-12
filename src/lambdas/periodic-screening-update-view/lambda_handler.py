import logging
import psycopg2
from datetime import datetime

from db_utils import get_connection

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    """
    Ejecuta el REFRESH de la Vista Materializada de PLD.
    """
    conn = None
    start_time = datetime.now()

    try:
        conn = get_connection()
        # REFRESH CONCURRENTLY no puede correr dentro de una transacción.
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
        logger.error("Error al refrescar la vista: %s", str(e))
        raise
    finally:
        if conn:
            conn.close()

