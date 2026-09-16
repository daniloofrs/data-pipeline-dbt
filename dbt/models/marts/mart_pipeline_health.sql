/*
    Camada Gold - saude do pipeline.
    Consolida as execucoes de ingestao por dia para responder rapido:
    o pipeline rodou? falhou? quantas linhas trouxe e quanto demorou?
*/

with runs as (

    select *
    from {{ ref('stg_ingestion_runs') }}

)

select
    run_date,
    count(*)                                              as total_runs,
    count(*) filter (where run_status = 'SUCCESS')        as successful_runs,
    count(*) filter (where run_status = 'FAILED')         as failed_runs,
    sum(rows_ingested)                                    as total_rows_ingested,
    round(avg(duration_seconds), 2)                       as avg_duration_seconds,
    max(duration_seconds)                                 as max_duration_seconds,
    max(started_at)                                       as last_run_started_at,
    round(
        count(*) filter (where run_status = 'SUCCESS')::numeric
            / nullif(count(*), 0) * 100, 2
    )                                                     as success_rate_pct
from runs
group by run_date
