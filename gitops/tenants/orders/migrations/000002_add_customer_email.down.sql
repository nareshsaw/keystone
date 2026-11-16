SET lock_timeout = '5s';
ALTER TABLE orders DROP COLUMN IF EXISTS customer_email;
