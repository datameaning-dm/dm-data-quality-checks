select
  cast(order_id as integer)        as order_id,
  cast(customer_id as integer)     as customer_id,
  status,
  cast(amount as decimal(12, 2))   as amount,
  cast(order_date as date)         as order_date,
  cast(ship_date as date)          as ship_date
from {{ ref('raw_orders') }}
