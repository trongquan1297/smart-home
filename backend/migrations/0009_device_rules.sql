-- Luật tự động theo từng thiết bị/gang (biểu tượng tia sét trong app).
--  * auto_off : sau khi gang BẬT được `delay_s` giây thì tự TẮT.
--  * auto_on  : sau khi gang TẮT được `delay_s` giây thì tự BẬT lại.
--  * link     : khi gang nguồn (source_device_id/source_key) chuyển sang source_state thì đặt gang này sang target_state.
-- Bộ chạy nằm trong backend: hẹn giờ lưu ở pending_actions nên sống sót qua khởi động lại.
CREATE TABLE device_rules (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id          uuid NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
  device_id        uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  key              text NOT NULL,
  kind             text NOT NULL CHECK (kind IN ('auto_off','auto_on','link')),
  delay_s          integer CHECK (delay_s BETWEEN 1 AND 86400),
  source_device_id uuid REFERENCES devices(id) ON DELETE CASCADE,
  source_key       text,
  source_state     text CHECK (source_state IN ('ON','OFF')),
  target_state     text CHECK (target_state IN ('ON','OFF')),
  enabled          boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CHECK ((kind = 'link' AND source_device_id IS NOT NULL AND source_key IS NOT NULL AND source_state IS NOT NULL AND target_state IS NOT NULL)
      OR (kind <> 'link' AND delay_s IS NOT NULL))
);
CREATE UNIQUE INDEX device_rules_timer_uq ON device_rules (device_id, key, kind) WHERE kind <> 'link';
CREATE INDEX device_rules_source_idx ON device_rules (source_device_id) WHERE kind = 'link';
CREATE INDEX device_rules_home_idx ON device_rules (home_id);

CREATE TABLE pending_actions (
  rule_id    uuid PRIMARY KEY REFERENCES device_rules(id) ON DELETE CASCADE,
  home_id    uuid NOT NULL,
  device_id  uuid NOT NULL,
  key        text NOT NULL,
  state      text NOT NULL CHECK (state IN ('ON','OFF')),
  due_at     timestamptz NOT NULL
);
CREATE INDEX pending_actions_due_idx ON pending_actions (due_at);
