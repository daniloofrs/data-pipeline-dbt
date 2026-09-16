-- Executado uma unica vez, na criacao do volume do Postgres.
-- Cria a arquitetura de schemas em camadas (medallion).
CREATE SCHEMA IF NOT EXISTS raw;        -- Bronze: dados crus, como vieram da API
CREATE SCHEMA IF NOT EXISTS staging;    -- Silver: limpo, tipado e deduplicado
CREATE SCHEMA IF NOT EXISTS marts;      -- Gold:   metricas de negocio

COMMENT ON SCHEMA raw IS 'Camada Bronze - ingestao bruta da API (append-only)';
COMMENT ON SCHEMA staging IS 'Camada Silver - dados limpos e padronizados (dbt)';
COMMENT ON SCHEMA marts IS 'Camada Gold - modelos analiticos e metricas (dbt)';
