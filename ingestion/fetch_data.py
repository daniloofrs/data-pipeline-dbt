"""
Camada Bronze - Ingestao de cotacoes de moedas da AwesomeAPI para o PostgreSQL.

O principio da camada Bronze e preservar o dado exatamente como a fonte entregou:
o payload de cada cotacao e gravado como JSONB, sem transformacao, acompanhado
de metadados de linhagem (par, fonte, execucao e horario de ingestao).
Toda a limpeza e tipagem acontece depois, no dbt (camadas Silver e Gold).

Uso:
    python ingestion/fetch_data.py
    python ingestion/fetch_data.py --pairs USD-BRL,EUR-BRL --days 90
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
import uuid
from datetime import datetime, timezone
from typing import Any

import psycopg2
import requests
from dotenv import load_dotenv
from psycopg2.extras import Json, execute_values

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("ingestion")

API_BASE_URL = "https://economia.awesomeapi.com.br/json"
SOURCE_NAME = "awesomeapi/economia"
REQUEST_TIMEOUT = 30
MAX_RETRIES = 3
RETRY_BACKOFF_SECONDS = 3

DDL_STATEMENTS = (
    "CREATE SCHEMA IF NOT EXISTS raw;",
    """
    CREATE TABLE IF NOT EXISTS raw.currency_quotes (
        id             BIGSERIAL    PRIMARY KEY,
        batch_id       UUID         NOT NULL,
        currency_pair  TEXT         NOT NULL,
        source         TEXT         NOT NULL,
        payload        JSONB        NOT NULL,
        ingested_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
    );
    """,
    "CREATE INDEX IF NOT EXISTS ix_currency_quotes_pair ON raw.currency_quotes (currency_pair);",
    "CREATE INDEX IF NOT EXISTS ix_currency_quotes_batch ON raw.currency_quotes (batch_id);",
    """
    CREATE TABLE IF NOT EXISTS raw.ingestion_runs (
        batch_id       UUID         PRIMARY KEY,
        source         TEXT         NOT NULL,
        currency_pairs TEXT[]       NOT NULL,
        rows_ingested  INTEGER      NOT NULL DEFAULT 0,
        status         TEXT         NOT NULL,
        error_message  TEXT,
        started_at     TIMESTAMPTZ  NOT NULL,
        finished_at    TIMESTAMPTZ
    );
    """,
)


# --------------------------------------------------------------------------- #
# Configuracao
# --------------------------------------------------------------------------- #
def build_db_config() -> dict[str, Any]:
    """Le as credenciais do banco a partir das variaveis de ambiente (.env)."""
    return {
        "host": os.getenv("POSTGRES_HOST", "localhost"),
        "port": int(os.getenv("POSTGRES_PORT", "5432")),
        "user": os.getenv("POSTGRES_USER", "dbt_user"),
        "password": os.getenv("POSTGRES_PASSWORD", "dbt_password"),
        "dbname": os.getenv("POSTGRES_DB", "data_warehouse"),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Ingestao de cotacoes (camada Bronze).")
    parser.add_argument(
        "--pairs",
        default=os.getenv("CURRENCY_PAIRS", "USD-BRL,EUR-BRL,GBP-BRL,BTC-BRL"),
        help="Pares de moedas separados por virgula (ex.: USD-BRL,EUR-BRL).",
    )
    parser.add_argument(
        "--days",
        type=int,
        default=int(os.getenv("HISTORY_DAYS", "180")),
        help="Quantidade de dias de historico por par (maximo 360).",
    )
    return parser.parse_args()


# --------------------------------------------------------------------------- #
# Extracao
# --------------------------------------------------------------------------- #
def request_json(url: str) -> Any:
    """GET com retry e backoff: a API publica ocasionalmente aplica rate limit."""
    last_error: Exception | None = None

    for attempt in range(1, MAX_RETRIES + 1):
        try:
            response = requests.get(url, timeout=REQUEST_TIMEOUT)
            response.raise_for_status()
            return response.json()
        except (requests.RequestException, json.JSONDecodeError) as error:
            last_error = error
            wait = RETRY_BACKOFF_SECONDS * attempt
            logger.warning(
                "Tentativa %s/%s falhou para %s (%s). Nova tentativa em %ss.",
                attempt, MAX_RETRIES, url, error, wait,
            )
            if attempt < MAX_RETRIES:
                time.sleep(wait)

    raise RuntimeError(f"Falha ao consultar {url}: {last_error}")


def fetch_available_pairs() -> dict[str, str]:
    """Catalogo de pares suportados pela API, no formato {par: nome legivel}."""
    return request_json(f"{API_BASE_URL}/available")


def fetch_daily_quotes(pair: str, days: int) -> list[dict[str, Any]]:
    """Historico diario de um par. A API devolve o registro mais recente primeiro."""
    payload = request_json(f"{API_BASE_URL}/daily/{pair}/{days}")

    if not isinstance(payload, list):
        raise RuntimeError(f"Resposta inesperada para {pair}: {payload!r}")

    return payload


# --------------------------------------------------------------------------- #
# Carga
# --------------------------------------------------------------------------- #
def ensure_schema(connection) -> None:
    """Cria schema, tabelas e indices da camada Bronze (idempotente)."""
    with connection.cursor() as cursor:
        for statement in DDL_STATEMENTS:
            cursor.execute(statement)
    connection.commit()
    logger.info("Camada Bronze pronta (schema raw).")


def start_run(connection, batch_id: str, pairs: list[str], started_at: datetime) -> None:
    with connection.cursor() as cursor:
        cursor.execute(
            """
            INSERT INTO raw.ingestion_runs
                (batch_id, source, currency_pairs, status, started_at)
            VALUES (%s, %s, %s, %s, %s);
            """,
            (batch_id, SOURCE_NAME, pairs, "RUNNING", started_at),
        )
    connection.commit()


def finish_run(connection, batch_id: str, rows: int, status: str, error: str | None = None) -> None:
    with connection.cursor() as cursor:
        cursor.execute(
            """
            UPDATE raw.ingestion_runs
               SET rows_ingested = %s,
                   status        = %s,
                   error_message = %s,
                   finished_at   = NOW()
             WHERE batch_id = %s;
            """,
            (rows, status, error, batch_id),
        )
    connection.commit()


def insert_quotes(connection, batch_id: str, pair: str, quotes: list[dict[str, Any]]) -> int:
    """Grava os payloads crus. Sem cast e sem dedup: isso e trabalho do dbt."""
    if not quotes:
        return 0

    records = [(batch_id, pair, SOURCE_NAME, Json(quote)) for quote in quotes]

    with connection.cursor() as cursor:
        execute_values(
            cursor,
            """
            INSERT INTO raw.currency_quotes (batch_id, currency_pair, source, payload)
            VALUES %s;
            """,
            records,
            page_size=500,
        )
    connection.commit()
    return len(records)


# --------------------------------------------------------------------------- #
# Orquestracao
# --------------------------------------------------------------------------- #
def main() -> int:
    args = parse_args()
    pairs = [pair.strip().upper() for pair in args.pairs.split(",") if pair.strip()]
    days = max(1, min(args.days, 360))

    if not pairs:
        logger.error("Nenhum par de moedas informado.")
        return 1

    batch_id = str(uuid.uuid4())
    started_at = datetime.now(timezone.utc)

    logger.info("Batch %s | pares=%s | dias=%s", batch_id, ",".join(pairs), days)

    try:
        available = fetch_available_pairs()
    except RuntimeError as error:
        logger.error("Nao foi possivel obter o catalogo de pares: %s", error)
        return 1

    unknown = [pair for pair in pairs if pair not in available]
    if unknown:
        logger.error("Pares nao suportados pela API: %s", ", ".join(unknown))
        return 1

    try:
        connection = psycopg2.connect(**build_db_config())
    except psycopg2.OperationalError as error:
        logger.error("Falha ao conectar no Postgres: %s", error)
        logger.error("O banco esta no ar? Rode: docker compose up -d")
        return 1

    total_rows = 0

    try:
        ensure_schema(connection)
        start_run(connection, batch_id, pairs, started_at)

        for pair in pairs:
            quotes = fetch_daily_quotes(pair, days)
            # Injeta o nome legivel do par: a API so o devolve no primeiro registro.
            for quote in quotes:
                quote.setdefault("name", available[pair])
                quote.setdefault("pair", pair)

            inserted = insert_quotes(connection, batch_id, pair, quotes)
            total_rows += inserted
            logger.info("%-10s -> %4d cotacoes gravadas em raw.currency_quotes", pair, inserted)

        finish_run(connection, batch_id, total_rows, "SUCCESS")
        logger.info("Ingestao concluida: %d linhas no batch %s", total_rows, batch_id)
        return 0

    except Exception as error:  # noqa: BLE001 - registra a falha no log de execucoes
        connection.rollback()
        finish_run(connection, batch_id, total_rows, "FAILED", str(error))
        logger.exception("Ingestao falhou: %s", error)
        return 1

    finally:
        connection.close()


if __name__ == "__main__":
    sys.exit(main())
