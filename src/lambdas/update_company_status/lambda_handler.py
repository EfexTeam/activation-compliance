import logging
from datetime import datetime

from db_utils import get_connection

logger = logging.getLogger()
logger.setLevel(logging.INFO)

INACTIVE_STATUS_ID = 1
ACTIVE_STATUS_ID = 2
OWNER_ROLE_ID = 1
FETCH_ITERSIZE = 2000
TIMEOUT_MARGIN_MS = 20000

def evaluate_enterprise_status(row):
    """
    Evaluación optimizada. 
    row: (id, current_status, is_full_register, is_kyc, has_valid_owner)
    """
    # Desempaquetado rápido
    _, _, is_full_reg, is_kyc, has_owner = row
    return ACTIVE_STATUS_ID if (is_full_reg and is_kyc and has_owner) else INACTIVE_STATUS_ID

def update_db_batch(cur, ids, status_id):
    if not ids: return 0
    query = "UPDATE enterprise_enterprise SET enterprise_operational_status_id = %s WHERE id = ANY(%s);"
    cur.execute(query, (status_id, ids))
    return cur.rowcount

def lambda_handler(event, context):
    start_time = datetime.now()
    conn = None
    stats = {"total": 0, "act": 0, "inact": 0, "timeout": False}

    try:
        conn = get_connection()
        
        # Cursor nombrado para Server-side streaming
        cursor_name = f"list_comp_cursor_{int(start_time.timestamp())}"
        
        with conn.cursor(name=cursor_name) as server_cur:
            server_cur.itersize = FETCH_ITERSIZE
            query = """
                        SELECT 
                            e.id,
                            e.enterprise_operational_status_id,
                            e.is_full_register,
                            e.is_kyc,
                            CASE 
                                WHEN valid_owners.enterprise_id IS NOT NULL THEN true
                                ELSE false
                            END as has_valid_owner
                        FROM enterprise_enterprise e
                        LEFT JOIN (
                            SELECT DISTINCT npe.enterprise_id
                            FROM users_user u
                            INNER JOIN enterprise_naturalperson np ON u.natural_person_id = np.id
                            INNER JOIN enterprise_naturalpersonenterprise npe 
                                ON np.id = npe.natural_person_id
                            WHERE u.user_role_id = %s
                                AND u.is_active = true
                                AND u.is_full_register = true
                                AND u.is_kyc = true
                                AND npe.is_active = true
                        ) valid_owners ON e.id = valid_owners.enterprise_id
                        ORDER BY e.id;
                    """
            server_cur.execute(query, (OWNER_ROLE_ID,))

            while True:
                # 1. Control de tiempo antes de cada lote
                if context.get_remaining_time_in_millis() < TIMEOUT_MARGIN_MS:
                    stats["timeout"] = True
                    break

                # 2. Fetch de micro-lote
                rows = server_cur.fetchmany(FETCH_ITERSIZE)
                if not rows: break
                
                stats["total"] += len(rows)

                # 3. LIST COMPREHENSIONS (El motor de alto rendimiento)
                # Creamos una lista de tuplas (id, target_status) solo para los que necesitan cambio
                changes = [
                    (r[0], evaluate_enterprise_status(r)) 
                    for r in rows 
                    if (r[1] or INACTIVE_STATUS_ID) != evaluate_enterprise_status(r)
                ]

                # Filtramos los IDs por cada estado objetivo usando más list comprehensions
                to_active = [id for id, target in changes if target == ACTIVE_STATUS_ID]
                to_inactive = [id for id, target in changes if target == INACTIVE_STATUS_ID]

                # 4. Updates inmediatos para liberar memoria
                if to_active or to_inactive:
                    with conn.cursor() as up_cur:
                        stats["act"] += update_db_batch(up_cur, to_active, ACTIVE_STATUS_ID)
                        stats["inact"] += update_db_batch(up_cur, to_inactive, INACTIVE_STATUS_ID)
                    conn.commit()

        return {
            "status": "SUCCESS" if not stats["timeout"] else "PARTIAL_TIMEOUT",
            "stats": stats,
            "duration": (datetime.now() - start_time).total_seconds()
        }

    except Exception as e:
        if conn:
            conn.rollback()
        logger.error("Error: %s", str(e))
        raise
    finally:
        if conn:
            conn.close()



