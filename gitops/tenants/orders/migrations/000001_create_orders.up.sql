-- Every migration sets timeouts: a migration that cannot get its lock fails fast instead of queueing
-- behind a long transaction and blocking all traffic behind it.
SET lock_timeout = '5s';
SET statement_timeout = '5min';

CREATE TABLE IF NOT EXISTS orders (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item       TEXT        NOT NULL CHECK (length(item) BETWEEN 1 AND 100),
    quantity   BIGINT      NOT NULL CHECK (quantity > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
