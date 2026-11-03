-- Allow managers to transfer all or part of a stock balance between customers.
-- Run after migracija_razdvajanje.sql. Safe to run more than once.
begin;

create or replace function public.transfer_stock(
  p_plant uuid, p_product uuid, p_serija text, p_from uuid, p_to uuid,
  p_qty int default null
)
returns void language plpgsql security definer set search_path=public as $$
declare
  available_qty bigint;
  transfer_qty bigint;
  source_name text;
  target_name text;
  transfer_key uuid := gen_random_uuid();
  tracks_customers boolean;
  transfer_date date := (now() at time zone 'Europe/Sarajevo')::date;
begin
  if not (can_plant(p_plant) or is_upravnik() or is_admin()) then
    raise exception 'Nemate pravo na ovaj magacin';
  end if;
  if p_from is null or p_to is null or p_from=p_to then
    raise exception 'Odaberite drugog kupca';
  end if;

  select tracks_customer into tracks_customers from plants where id=p_plant;
  if tracks_customers is null then raise exception 'Nepoznat magacin'; end if;
  if not exists(select 1 from customers c where c.id=p_from
    and (c.plant_id=p_plant or (c.plant_id is null and tracks_customers))) then
    raise exception 'Kupac ne pripada ovom magacinu';
  end if;
  if not exists(select 1 from customers c where c.id=p_to
    and (c.plant_id=p_plant or (c.plant_id is null and tracks_customers))) then
    raise exception 'Kupac ne pripada ovom magacinu';
  end if;

  -- Serialize transfers of the same product before checking its balance.
  perform 1 from products where id=p_product for update;
  if not found then raise exception 'Nepoznat proizvod'; end if;
  select coalesce(sum(qty_in-qty_out),0) into available_qty from movements
    where plant_id=p_plant and product_id=p_product
      and coalesce(serija,'')=coalesce(p_serija,'')
      and customer_id=p_from and status='kontrola';
  transfer_qty := coalesce(p_qty,available_qty);
  if transfer_qty<=0 or transfer_qty>available_qty or transfer_qty>2147483647 then
    raise exception 'Neispravna kolicina (stanje: %)', available_qty;
  end if;

  select name into source_name from customers where id=p_from;
  select name into target_name from customers where id=p_to;
  insert into movements(date,plant_id,customer_id,product_id,serija,qty_out,note,kind,transfer_id,status)
    values(transfer_date,p_plant,p_from,p_product,coalesce(p_serija,''),transfer_qty,
      'Prebaceno na: '||target_name,'prebacivanje',transfer_key,'kontrola');
  insert into movements(date,plant_id,customer_id,product_id,serija,qty_in,note,kind,transfer_id,status)
    values(transfer_date,p_plant,p_to,p_product,coalesce(p_serija,''),transfer_qty,
      'Prebaceno sa: '||source_name,'prebacivanje',transfer_key,'kontrola');
end $$;

revoke all on function public.transfer_stock(uuid,uuid,text,uuid,uuid,int) from public;
grant execute on function public.transfer_stock(uuid,uuid,text,uuid,uuid,int) to authenticated;

commit;
