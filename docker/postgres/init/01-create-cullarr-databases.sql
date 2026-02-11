SELECT format('CREATE DATABASE %I', 'cullarr_production')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'cullarr_production') \gexec

SELECT format('CREATE DATABASE %I', 'cullarr_cache_production')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'cullarr_cache_production') \gexec

SELECT format('CREATE DATABASE %I', 'cullarr_queue_production')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'cullarr_queue_production') \gexec

SELECT format('CREATE DATABASE %I', 'cullarr_cable_production')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'cullarr_cable_production') \gexec
