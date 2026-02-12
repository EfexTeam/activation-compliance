"""
Utilidades compartidas para Secrets Manager y conexión a PostgreSQL.
Todas las lambdas del proyecto utilizan este módulo para estandarizar
acceso a credenciales y conexión a la BD.
"""
import os
import json
import logging
import boto3
import psycopg2

logger = logging.getLogger(__name__)

_session = None
_secrets_client = None
_creds_cache = None


def _get_secrets_client():
    global _session, _secrets_client
    if _secrets_client is None:
        _session = boto3.session.Session()
        _secrets_client = _session.client(service_name="secretsmanager")
    return _secrets_client


def get_secret():
    """
    Obtiene las credenciales de BD desde AWS Secrets Manager.
    Usa variable de entorno SECRET_NAME. Cachea el resultado por invocación
    en el mismo contenedor (Lambda warm start).
    """
    global _creds_cache
    if _creds_cache is not None:
        return _creds_cache
    secret_name = os.environ.get("SECRET_NAME")
    if not secret_name:
        raise ValueError("Variable de entorno SECRET_NAME no está definida")
    client = _get_secrets_client()
    response = client.get_secret_value(SecretId=secret_name)
    _creds_cache = json.loads(response["SecretString"])
    return _creds_cache


def get_connection(creds=None, connect_timeout=5, **kwargs):
    """
    Crea una conexión a PostgreSQL.

    :param creds: Diccionario con host, dbname, username, password, port (opcional).
                  Si es None, se obtiene con get_secret().
    :param connect_timeout: Timeout de conexión en segundos.
    :param kwargs: Parámetros adicionales para psycopg2.connect (ej. connect_timeout).
    :return: Conexión psycopg2.
    """
    if creds is None:
        creds = get_secret()
    return psycopg2.connect(
        host=creds["host"],
        database=creds["dbname"],
        user=creds["username"],
        password=creds["password"],
        port=creds.get("port", 5432),
        connect_timeout=connect_timeout,
        **kwargs,
    )
