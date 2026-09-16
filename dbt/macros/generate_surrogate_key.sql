{#
    Chave substituta deterministica a partir de uma lista de colunas.
    Equivale ao dbt_utils.generate_surrogate_key, mas sem dependencia externa:
    o projeto roda com `dbt build` puro, sem precisar de `dbt deps`.

    Uso:  {{ generate_surrogate_key(['currency_pair', 'quoted_at']) }}
#}
{% macro generate_surrogate_key(field_list) -%}

    {%- set fields = [] -%}
    {%- for field in field_list -%}
        {%- do fields.append(
            "coalesce(cast(" ~ field ~ " as varchar), '_dbt_null_')"
        ) -%}
    {%- endfor -%}

    md5({{ fields | join(" || '-' || ") }})

{%- endmacro %}
