-- Test fixtures for an EMPTY, DISPOSABLE database only.
-- Run with: psql -v ON_ERROR_STOP=1 -f tests/transfer-stock.sql
create role authenticated;
create function can_plant(uuid) returns boolean language sql as
  $$ select coalesce(current_setting('test.can_plant',true),'false')='true' $$;
create function is_upravnik() returns boolean language sql as
  $$ select coalesce(current_setting('test.manager',true),'false')='true' $$;
create function is_admin() returns boolean language sql as
  $$ select coalesce(current_setting('test.admin',true),'false')='true' $$;
create table plants(id uuid primary key,tracks_customer boolean not null);
create table products(id uuid primary key);
create table customers(id uuid primary key,name text not null,plant_id uuid references plants);
create table movements(
  id uuid primary key default gen_random_uuid(), date date default current_date,
  plant_id uuid references plants,customer_id uuid references customers,product_id uuid references products,
  serija text,qty_in integer not null default 0,qty_out integer not null default 0,
  note text,kind text,transfer_id uuid,status text
);
insert into plants values('00000000-0000-0000-0000-000000000001',true),('00000000-0000-0000-0000-000000000002',true);
insert into products values('00000000-0000-0000-0000-000000000101');
insert into customers values
  ('00000000-0000-0000-0000-000000000201','Bulgaria',null),
  ('00000000-0000-0000-0000-000000000202','Turkey',null),
  ('00000000-0000-0000-0000-000000000203','Other warehouse','00000000-0000-0000-0000-000000000002');
insert into movements(plant_id,customer_id,product_id,serija,qty_in,status)
select '00000000-0000-0000-0000-000000000001',id,'00000000-0000-0000-0000-000000000101','S1',100,'kontrola'
from customers where plant_id is null;

\ir ../migracija_promjena_kupca.sql
\ir ../migracija_promjena_kupca.sql

do $$
declare
  warehouse uuid := '00000000-0000-0000-0000-000000000001';
  product uuid := '00000000-0000-0000-0000-000000000101';
  source uuid := '00000000-0000-0000-0000-000000000201';
  target uuid := '00000000-0000-0000-0000-000000000202';
  wrong_customer uuid := '00000000-0000-0000-0000-000000000203';
begin
  begin
    perform transfer_stock(warehouse,product,'S1',source,target,40);
    raise exception 'Unauthorized transfer succeeded';
  exception when others then
    if sqlerrm not like 'Nemate pravo%' then raise; end if;
  end;
  perform set_config('test.manager','true',false);
  perform transfer_stock(warehouse,product,'S1',source,target,40);
  if (select sum(qty_in-qty_out) from movements where customer_id=source)<>60 then
    raise exception 'Partial transfer did not leave 60 with source';
  end if;
  if (select sum(qty_in-qty_out) from movements where customer_id=target)<>140 then
    raise exception 'Partial transfer did not add to existing target stock';
  end if;
  begin
    perform transfer_stock(warehouse,product,'S1',source,target,61);
    raise exception 'Overdraw succeeded';
  exception when others then
    if sqlerrm not like 'Neispravna kolicina%' then raise; end if;
  end;
  begin
    perform transfer_stock(warehouse,product,'S1',source,wrong_customer,1);
    raise exception 'Cross-warehouse customer transfer succeeded';
  exception when others then
    if sqlerrm<>'Kupac ne pripada ovom magacinu' then raise; end if;
  end;
  begin
    perform transfer_stock(warehouse,product,'S1',source,source,1);
    raise exception 'Same-customer transfer succeeded';
  exception when others then
    if sqlerrm<>'Odaberite drugog kupca' then raise; end if;
  end;
  perform transfer_stock(warehouse,product,'S1',source,target);
  if (select sum(qty_in-qty_out) from movements where customer_id=source)<>0 then
    raise exception 'Full transfer did not empty source';
  end if;
  if (select sum(qty_in-qty_out) from movements where customer_id=target)<>200 then
    raise exception 'Full transfer did not combine target stock';
  end if;
  if (select sum(qty_in-qty_out) from movements)<>200 then
    raise exception 'Warehouse total changed';
  end if;
  if exists(select 1 from movements where kind='prebacivanje' and date<>(now() at time zone 'Europe/Sarajevo')::date) then
    raise exception 'Transfer business date is incorrect';
  end if;
  if exists(select transfer_id from movements where transfer_id is not null
    group by transfer_id having count(*)<>2 or sum(qty_in-qty_out)<>0) then
    raise exception 'Unbalanced transfer pair';
  end if;
end $$;

-- A failure while crediting the target must also roll back the source debit.
create function reject_test_credit() returns trigger language plpgsql as $$
begin
  if new.kind='prebacivanje' and new.qty_in>0 then raise exception 'Test credit rejected'; end if;
  return new;
end $$;
create trigger reject_test_credit before insert on movements for each row execute function reject_test_credit();
do $$
begin
  begin
    perform transfer_stock('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000101',
      'S1','00000000-0000-0000-0000-000000000202','00000000-0000-0000-0000-000000000201',10);
    raise exception 'Rejected credit succeeded';
  exception when others then
    if sqlerrm<>'Test credit rejected' then raise; end if;
  end;
  if (select sum(qty_in-qty_out) from movements where customer_id='00000000-0000-0000-0000-000000000202')<>200 then
    raise exception 'Failed transfer changed source stock';
  end if;
end $$;
select 'PASS: authorization, partial and full transfers, existing target stock, overdraw prevention, customer scope, dates, balanced entries, rollback, and migration idempotence.' as result;
