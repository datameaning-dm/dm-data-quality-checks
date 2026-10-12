select
  cast(customer_id as integer)     as customer_id,
  email,
  country,
  cast(signup_at as timestamp)     as signup_at
from {{ source('landing', 'raw_customers') }}
