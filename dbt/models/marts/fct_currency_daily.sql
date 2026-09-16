/*
    Camada Gold - fato diario de cambio.

    Grao: um registro por (currency_pair, quote_date).
    A camada Silver pode ter varias cotacoes intradiarias do mesmo dia (a API
    devolve a cotacao ao vivo a cada execucao); aqui consolidamos o dia pelo
    fechamento, ou seja, a ultima cotacao registrada naquela data.

    Metricas entregues prontas para o BI:
      - fechamento, maxima, minima e amplitude do dia;
      - variacao absoluta e percentual contra o dia anterior;
      - medias moveis de 7 e 30 dias;
      - volatilidade (desvio padrao movel de 7 dias).
*/

with quotes as (

    select *
    from {{ ref('stg_currency_quotes') }}

),

ranked as (

    select
        *,
        row_number() over (
            partition by currency_pair, quote_date
            order by quoted_at desc, quote_id desc
        ) as row_num
    from quotes

),

daily as (

    select
        currency_pair,
        currency_pair_name,
        base_currency,
        quote_currency,
        quote_date,
        quoted_at                       as closing_quoted_at,
        bid_price                       as close_bid_price,
        ask_price                       as close_ask_price,
        high_price,
        low_price,
        spread_abs,
        variation_abs                   as source_variation_abs,
        variation_pct                   as source_variation_pct
    from ranked
    where row_num = 1

),

with_metrics as (

    select
        *,

        lag(close_bid_price) over pair_by_date        as previous_close_bid_price,

        round(
            avg(close_bid_price) over (
                pair_by_date rows between 6 preceding and current row
            ), 6
        )                                             as moving_avg_7d,

        round(
            avg(close_bid_price) over (
                pair_by_date rows between 29 preceding and current row
            ), 6
        )                                             as moving_avg_30d,

        round(
            coalesce(
                stddev_samp(close_bid_price) over (
                    pair_by_date rows between 6 preceding and current row
                ), 0
            ), 6
        )                                             as volatility_7d,

        max(close_bid_price) over (
            pair_by_date rows between unbounded preceding and current row
        )                                             as running_max_bid_price,

        min(close_bid_price) over (
            pair_by_date rows between unbounded preceding and current row
        )                                             as running_min_bid_price

    from daily
    window pair_by_date as (partition by currency_pair order by quote_date)

)

select
    {{ generate_surrogate_key(['currency_pair', 'quote_date']) }} as daily_quote_key,
    {{ generate_surrogate_key(['currency_pair']) }}               as currency_pair_key,

    currency_pair,
    currency_pair_name,
    base_currency,
    quote_currency,

    quote_date,
    closing_quoted_at,
    extract(year  from quote_date)::int              as quote_year,
    extract(month from quote_date)::int              as quote_month,
    to_char(quote_date, 'YYYY-MM')                   as quote_year_month,
    trim(to_char(quote_date, 'Day'))                 as quote_weekday,

    close_bid_price,
    close_ask_price,
    high_price,
    low_price,
    spread_abs,
    round(high_price - low_price, 6)                 as intraday_range,

    previous_close_bid_price,
    round(close_bid_price - previous_close_bid_price, 6) as daily_change_abs,
    case
        when previous_close_bid_price is null or previous_close_bid_price = 0 then null
        else round(
            (close_bid_price - previous_close_bid_price) / previous_close_bid_price * 100, 4
        )
    end                                              as daily_change_pct,

    moving_avg_7d,
    moving_avg_30d,
    volatility_7d,
    running_max_bid_price,
    running_min_bid_price,

    -- Rotulo de tendencia pronto para dashboards
    case
        when previous_close_bid_price is null then 'SEM_REFERENCIA'
        when close_bid_price > previous_close_bid_price then 'ALTA'
        when close_bid_price < previous_close_bid_price then 'BAIXA'
        else 'ESTAVEL'
    end                                              as daily_trend,

    -- Indica se o fechamento do dia foi o maior ja observado na serie
    (close_bid_price >= running_max_bid_price)       as is_record_high,

    source_variation_abs,
    source_variation_pct
from with_metrics
