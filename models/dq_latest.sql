{#- Each rule's state now. Rules with no result yet are kept, as status 'no result',
    so the report shows coverage gaps instead of hiding them. -#}
with ranked as (
  select
    *,
    row_number() over (partition by rule_id order by measured_at desc) as rn
  from {{ ref('dq_results') }}
)

select
  c.rule_id,
  c.rule_name,
  c.table_full_name,
  c.table_name,
  c.column_name,
  c.rule_type,
  c.dimension,
  c.severity,
  c.steward,
  r.measured_at                                   as last_measured_at,
  r.metric_value                                  as last_metric_value,
  case
    when r.rule_id is null then 'no result'
    when r.passed_flag = 1 then 'pass'
    else 'fail'
  end                                             as status
from {{ ref('dq_rule_catalog') }} c
left join ranked r
  on r.rule_id = c.rule_id
 and r.rn = 1
where c.status = 'active'
