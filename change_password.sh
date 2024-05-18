#!/bin/bash

old_passwd=`grep POSTGRES_PASSWORD= .env | sed "s/.*=\(.*\)/\1/"`
if [ -z $1 ]; then
    echo "Please specify a new password"
    exit 1
fi
new_passwd=$1

PGPASSWORD=$old_passwd psql -h 127.0.0.1 -p 5432 -d postgres -U supabase_admin << EOT
    alter user anon with password '$new_passwd';
    alter user authenticated with password '$new_passwd';
    alter user authenticator with password '$new_passwd';
    alter user dashboard_user with password '$new_passwd';
    alter user pgbouncer with password '$new_passwd';
    alter user pgsodium_keyholder with password '$new_passwd';
    alter user pgsodium_keyiduser with password '$new_passwd';
    alter user pgsodium_keymaker with password '$new_passwd';
    alter user postgres with password '$new_passwd';
    alter user service_role with password '$new_passwd';
    alter user supabase_admin with password '$new_passwd';
    alter user supabase_auth_admin with password '$new_passwd';
    alter user supabase_functions_admin with password '$new_passwd';
    alter user supabase_read_only_user with password '$new_passwd';
    alter user supabase_replication_admin with password '$new_passwd';
    alter user supabase_storage_admin with password '$new_passwd';

    UPDATE _analytics.source_backends
    SET config = jsonb_set(config, '{url}', '"postgresql://supabase_admin:$new_passwd@db:5432/postgres"', 'false')
    WHERE type='postgres';
EOT

if [ $? -eq 0 ]; then
    sed -i -e "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$new_passwd/g" .env
fi
