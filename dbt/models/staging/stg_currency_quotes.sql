/*
    Camada Silver - limpeza da cotacao bruta.

    Responsabilidades deste modelo:
      1. Extrair os campos do JSONB e aplicar os tipos corretos (numeric / timestamp);
      2. Tratar nulos e strings vazias vindas da API;
      3. Remover duplicatas - o mesmo dia e reingerido a cada execucao, entao
         mantemos apenas o registro mais recente por (par, timestamp da cotacao).
*/

with source as (

    select
        id,
        batch_id,
        currency_pair,
        source,
        payload,
        ingested_at
    from {{ source('raw', 'currency_quotes') }}

),

extracted as (

    select
        id                                          as quote_id,
        batch_id,
        upper(trim(currency_pair))                  as currency_pair,
        source                                      as source_system,

        -- Moeda base e moeda de cotacao (ex.: USD-BRL -> USD e BRL)
        split_part(upper(trim(currency_pair)), '-', 1) as base_currency,
        split_part(upper(trim(currency_pair)), '-', 2) as quote_currency,
        nullif(trim(payload ->> 'name'), '')        as currency_pair_name,

        -- Precos: a API entrega numeros como string; nullif evita cast de vazio
        nullif(payload ->> 'bid', '')::numeric(20, 6)       as bid_price,
        nullif(payload ->> 'ask', '')::numeric(20, 6)       as ask_price,
        nullif(payload ->> 'high', '')::numeric(20, 6)      as high_price,
        nullif(payload ->> 'low', '')::numeric(20, 6)       as low_price,
        nullif(payload ->> 'varBid', '')::numeric(20, 6)    as variation_abs,
        nullif(payload ->> 'pctChange', '')::numeric(12, 6) as variation_pct,

        -- Epoch (segundos) -> timestamp; a data de negocio usa o fuso de Sao Paulo
        to_timestamp(nullif(payload ->> 'timestamp', '')::bigint) as quoted_at,
        (to_timestamp(nullif(payload ->> 'timestamp', '')::bigint)
            at time zone 'America/Sao_Paulo')::date               as quote_date,

        ingested_at
    from source

),

cleaned as (

    select *
    from extracted
    where quoted_at is not null          -- sem carimbo de tempo o registro e inutilizavel
      and bid_price is not null          -- cotacao sem preco de compra nao entra no Silver
      and bid_price > 0
      and currency_pair is not null

),

deduplicated as (

    select
        *,
        row_number() over (
            partition by currency_pair, quoted_at
            order by ingested_at desc, quote_id desc
        ) as row_num
    from cleaned

)

select
    -- Chave substituta estavel do grao (par + instante da cotacao)
    {{ generate_surrogate_key(['currency_pair', 'quoted_at']) }}         as quote_key,
    quote_id,
    batch_id,
    currency_pair,
    currency_pair_name,
    base_currency,
    quote_currency,
    source_system,
    bid_price,
    ask_price,
    high_price,
    low_price,
    -- Spread: quanto o mercado cobra entre compra e venda
    round(ask_price - bid_price, 6)                  as spread_abs,
    variation_abs,
    variation_pct,
    quoted_at,
    quote_date,
    ingested_at
from deduplicated
where row_num = 1
