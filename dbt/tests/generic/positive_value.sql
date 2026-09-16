{#
    Teste generico customizado: falha se a coluna tiver valores <= 0.
    Preco de cambio negativo ou zerado e sempre erro de dado, nunca regra de negocio.

    Uso no .yml:
        data_tests:
          - positive_value
#}
{% test positive_value(model, column_name) %}

    select {{ column_name }}
    from {{ model }}
    where {{ column_name }} is not null
      and {{ column_name }} <= 0

{% endtest %}
