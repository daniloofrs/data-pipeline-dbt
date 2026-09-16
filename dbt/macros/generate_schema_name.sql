{#
    Por padrao o dbt cria schemas com prefixo (ex.: public_staging).
    Esta macro faz o dbt usar exatamente o schema declarado no dbt_project.yml,
    resultando em `staging` e `marts` limpos, como na arquitetura desenhada.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
