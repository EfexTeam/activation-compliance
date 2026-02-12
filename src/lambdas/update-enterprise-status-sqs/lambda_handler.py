import json
import logging

from db_utils import get_connection

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def _process_record(cur, record):
    """Process a single SQS record. Returns True if processed, False if skipped."""
    payload = json.loads(record["body"])
    id_empresa = payload.get("id_empresa") or payload.get("enterprise_id")
    nuevo_estatus = payload.get("estatus") or payload.get(
        "enterprise_operational_status_id"
    )

    if id_empresa is None or nuevo_estatus is None:
        logger.warning("Mensaje omitido por payload incompleto: %s", payload)
        return False

    cur.execute(
        """
        UPDATE enterprise_enterprise
        SET enterprise_operational_status_id = %s
        WHERE id = %s
        """,
        (nuevo_estatus, id_empresa),
    )
    return True


def lambda_handler(event, context):
    conn = None
    cur = None
    try:
        conn = get_connection()
        cur = conn.cursor()

        processed = 0
        for record in event["Records"]:
            if _process_record(cur, record):
                processed += 1

        conn.commit()
        logger.info("Procesados %d registros con éxito.", processed)
        return {"statusCode": 200, "processed": processed}

    except Exception as e:
        if conn:
            conn.rollback()
        logger.exception("Error procesando mensajes: %s", str(e))
        raise
    finally:
        if cur is not None:
            try:
                cur.close()
            except Exception as e:
                logger.warning("Error cerrando cursor: %s", e)
        if conn is not None:
            try:
                conn.close()
            except Exception as e:
                logger.warning("Error cerrando conexión: %s", e)