/*
    Camada Silver - execucoes do pipeline de ingestao.
    Modelo de observabilidade: permite responder "o pipeline rodou hoje?
    quantas linhas entraram? quanto tempo levou?" direto no SQL.
*/

with source as (

    select *
    from {{ source('raw', 'ingestion_runs') }}

)

select
    batch_id,
    source                                          as source_system,
    currency_pairs,
    array_length(currency_pairs, 1)                 as currency_pairs_count,
    rows_ingested,
    upper(trim(status))                             as run_status,
    nullif(trim(error_message), '')                 as error_message,
    started_at,
    finished_at,
    round(
        extract(epoch from (coalesce(finished_at, now()) - started_at))::numeric,
        2
    )                                               as duration_seconds,
    (started_at at time zone 'America/Sao_Paulo')::date as run_date
from source
