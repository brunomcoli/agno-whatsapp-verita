"""
Database Session
----------------

PostgreSQL database connection for AgentOS.
"""

from functools import lru_cache
from os import getenv
from typing import Any

from agno.db.postgres import PostgresDb
from agno.db.utils import json_serializer
from agno.knowledge import Knowledge
from agno.knowledge.embedder.openai import OpenAIEmbedder
from agno.vectordb.pgvector import PgVector, SearchType
from sqlalchemy import create_engine
from sqlalchemy.engine import Engine

from db.url import db_url

DB_ID = "agentos-db"

# O AgentOS cria as tabelas dentro do lifespan do uvicorn, ou seja, ANTES da
# porta HTTP aceitar conexoes. Sem limite de connect o psycopg fica preso ate o
# timeout do SO (~130s) e o healthcheck da Railway expira sem o app nunca subir.
_DEFAULT_CONNECT_TIMEOUT = 10
# A rede privada da Railway derruba conexoes ociosas; reciclar antes disso
# evita "server closed the connection unexpectedly" na primeira msg do dia.
_DEFAULT_POOL_RECYCLE = 1800


def _int_env(name: str, default: int) -> int:
    """Le um inteiro do ambiente, caindo no default se vier vazio ou invalido."""
    try:
        return int(getenv(name, "").strip() or default)
    except ValueError:
        return default


def _connect_args() -> dict[str, Any]:
    """Parametros libpq. So valem para os drivers psycopg."""
    driver = db_url.split("://", 1)[0]
    if "psycopg" not in driver:
        return {}

    return {
        "connect_timeout": _int_env("DB_CONNECT_TIMEOUT", _DEFAULT_CONNECT_TIMEOUT),
        # Keepalives TCP: a rede privada da Railway e IPv6 e corta sessoes paradas.
        "keepalives": 1,
        "keepalives_idle": 30,
        "keepalives_interval": 10,
        "keepalives_count": 5,
        "application_name": getenv("RAILWAY_SERVICE_NAME", "agentos"),
    }


@lru_cache(maxsize=1)
def get_db_engine() -> Engine:
    """Engine unica, compartilhada por todos os PostgresDb do processo.

    Sem isso cada `get_postgres_db()` cria a propria engine e o proprio pool
    (agent + AgentOS = 2 pools), dobrando as conexoes abertas no Postgres.
    """
    return create_engine(
        db_url,
        # `json_serializer` replica o que o PostgresDb faz internamente quando
        # recebe `db_url`. Omitir quebra a escrita das colunas JSON do Agno.
        json_serializer=json_serializer,
        pool_pre_ping=True,  # descarta conexao morta antes de entregar pro app
        pool_recycle=_int_env("DB_POOL_RECYCLE", _DEFAULT_POOL_RECYCLE),
        pool_size=_int_env("DB_POOL_SIZE", 5),
        max_overflow=_int_env("DB_MAX_OVERFLOW", 5),
        pool_timeout=_int_env("DB_POOL_TIMEOUT", 30),
        connect_args=_connect_args(),
    )


def get_postgres_db(contents_table: str | None = None) -> PostgresDb:
    """Create a PostgresDb instance.

    Args:
        contents_table: Optional table name for storing knowledge contents.

    Returns:
        Configured PostgresDb instance.
    """
    engine = get_db_engine()
    if contents_table is not None:
        return PostgresDb(id=DB_ID, db_engine=engine, knowledge_table=contents_table)
    return PostgresDb(id=DB_ID, db_engine=engine)


def create_knowledge(name: str, table_name: str) -> Knowledge:
    """Create a Knowledge instance with PgVector hybrid search.

    Args:
        name: Display name for the knowledge base.
        table_name: PostgreSQL table name for vector storage.

    Returns:
        Configured Knowledge instance.
    """
    return Knowledge(
        name=name,
        vector_db=PgVector(
            db_engine=get_db_engine(),
            table_name=table_name,
            search_type=SearchType.hybrid,
            embedder=OpenAIEmbedder(id="text-embedding-3-small"),
        ),
        contents_db=get_postgres_db(contents_table=f"{table_name}_contents"),
    )
