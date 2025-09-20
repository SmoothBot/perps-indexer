-- Rollback migration: Remove hourly user stats materialized view

-- Drop the refresh function
DROP FUNCTION IF EXISTS refresh_hourly_user_stats();

-- Drop the materialized view (this will also drop all its indexes)
DROP MATERIALIZED VIEW IF EXISTS hl_hourly_user_stats;