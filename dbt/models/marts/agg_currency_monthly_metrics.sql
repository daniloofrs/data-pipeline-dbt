/*
    Camada Gold - metricas mensais de cambio.

    Grao: um registro por (currency_pair, month_start_date).
    Responde as perguntas classicas de negocio: como o dolar fechou o mes,
    quanto variou da abertura ao fechamento, qual foi a volatilidade e
    qual a amplitude entre minima e maxima do periodo.
*/

with daily as (

    select *
    from {{ ref('fct_currency_daily') }}

),

with_month as (

    select
        *,
        date_trunc('month', quote_date)::date as month_start_date,

        first_value(close_bid_price) over (
            partition by currency_pair, date_trunc('month', quote_date)
            order by quote_date
            rows between unbounded preceding and unbounded following
        ) as month_open_price,

        last_value(close_bid_price) over (
            partition by currency_pair, date_trunc('month', quote_date)
            order by quote_date
            rows between unbounded preceding and unbounded following
        ) as month_close_price

    from daily

),

aggregated as (

    select
        currency_pair,
        max(currency_pair_name)                     as currency_pair_name,
        max(base_currency)                          as base_currency,
        max(quote_currency)                         as quote_currency,
        month_start_date,
        to_char(month_start_date, 'YYYY-MM')        as year_month,

        count(*)                                    as trading_days,
        max(month_open_price)                       as month_open_price,
        max(month_close_price)                      as month_close_price,
        round(avg(close_bid_price), 6)              as avg_bid_price,
        min(low_price)                              as min_price,
        max(high_price)                             as max_price,
        round(coalesce(stddev_samp(close_bid_price), 0), 6) as volatility,
        round(avg(spread_abs), 6)                   as avg_spread,
        round(avg(abs(daily_change_pct)), 4)        as avg_abs_daily_change_pct,
        count(*) filter (where daily_trend = 'ALTA')  as up_days,
        count(*) filter (where daily_trend = 'BAIXA') as down_days
    from with_month
    group by currency_pair, month_start_date

)

select
    {{ generate_surrogate_key(['currency_pair', 'month_start_date']) }} as monthly_metrics_key,
    {{ generate_surrogate_key(['currency_pair']) }}                     as currency_pair_key,

    currency_pair,
    currency_pair_name,
    base_currency,
    quote_currency,
    month_start_date,
    year_month,
    trading_days,

    month_open_price,
    month_close_price,
    avg_bid_price,
    min_price,
    max_price,
    round(max_price - min_price, 6)                 as price_amplitude,

    round(month_close_price - month_open_price, 6)  as month_change_abs,
    case
        when month_open_price is null or month_open_price = 0 then null
        else round((month_close_price - month_open_price) / month_open_price * 100, 4)
    end                                             as month_change_pct,

    volatility,
    -- Volatilidade relativa: comparavel entre moedas de escalas diferentes
    case
        when avg_bid_price is null or avg_bid_price = 0 then null
        else round(volatility / avg_bid_price * 100, 4)
    end                                             as volatility_pct,

    avg_spread,
    avg_abs_daily_change_pct,
    up_days,
    down_days,

    case
        when month_close_price > month_open_price then 'VALORIZACAO'
        when month_close_price < month_open_price then 'DESVALORIZACAO'
        else 'ESTAVEL'
    end                                             as month_trend
from aggregated
