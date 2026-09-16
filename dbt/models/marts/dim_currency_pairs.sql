/*
    Camada Gold - dimensao de pares de moedas.
    Um registro por par monitorado, com o periodo coberto pelo historico.
    Serve de filtro e rotulo para os fatos e agregacoes.
*/

with quotes as (

    select *
    from {{ ref('stg_currency_quotes') }}

),

aggregated as (

    select
        currency_pair,
        max(currency_pair_name)         as currency_pair_name,
        max(base_currency)              as base_currency,
        max(quote_currency)             as quote_currency,
        count(*)                        as total_quotes,
        count(distinct quote_date)      as total_days_covered,
        min(quote_date)                 as first_quote_date,
        max(quote_date)                 as last_quote_date,
        max(ingested_at)                as last_ingested_at
    from quotes
    group by currency_pair

)

select
    {{ generate_surrogate_key(['currency_pair']) }} as currency_pair_key,
    currency_pair,
    currency_pair_name,
    base_currency,
    quote_currency,
    total_quotes,
    total_days_covered,
    first_quote_date,
    last_quote_date,
    (last_quote_date - first_quote_date)            as history_span_days,
    last_ingested_at,
    -- Um par sem cotacao nos ultimos 7 dias provavelmente parou de ser coletado
    (last_quote_date >= current_date - 7)           as is_active
from aggregated
