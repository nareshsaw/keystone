-- No lock_timeout: if a long transaction holds a lock, this waits and blocks all traffic behind it.
ALTER TABLE orders ADD COLUMN IF NOT EXISTS note TEXT;
