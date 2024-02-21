-- WARNING!! DO NOT RUN THIS IN PRODUCTION
-- WARNING!! DO NOT RUN THIS IN PRODUCTION
-- WARNING!! DO NOT RUN THIS IN PRODUCTION
-- WARNING!! DO NOT RUN THIS IN PRODUCTION
-- WARNING!! DO NOT RUN THIS IN PRODUCTION
do $$ declare
    r record;
begin
    for r in (select tablename from pg_tables where schemaname = 'public') loop
        execute 'drop table if exists ' || quote_ident(r.tablename) || ' cascade';
    end loop;
end $$;
