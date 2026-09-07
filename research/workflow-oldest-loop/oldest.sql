SELECT r.id
FROM run AS r
WHERE r.terminal = 0 AND r.cancelled = 0
  AND (
    r.published_generation IS NULL
    OR r.active_generation IS NOT NULL
    OR EXISTS (
      SELECT 1
      FROM pending AS p
      JOIN call_binding AS c ON c.run_id = p.run_id AND c.key = p.key
      JOIN result_owner AS o ON o.id = c.result_id
      WHERE p.run_id = r.id AND o.available = 1
    )
  )
ORDER BY r.created_at, r.id
LIMIT 1;
