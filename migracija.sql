-- MIGRACIJA postojeće baze (pokreni kao rola postgres). NE briše podatke.
alter table plants add column if not exists is_main boolean not null default false;
alter table movements add column if not exists transfer_id uuid;
insert into plants(name,is_main) values('Glavni magacin',true)
  on conflict ((lower(name))) do update set is_main=true;

-- ===== RUTE, PREBACIVANJE IZMEĐU POGONA, OTPREMA, KOREKCIJE =====
create table if not exists routes(id uuid primary key default gen_random_uuid(),
  from_plant uuid not null references plants on delete cascade, to_plant uuid not null references plants on delete cascade,
  unique(from_plant,to_plant), check(from_plant<>to_plant));
alter table routes enable row level security;
drop policy if exists "routes read" on routes; drop policy if exists "routes add" on routes; drop policy if exists "routes del" on routes;
create policy "routes read" on routes for select to authenticated using (true);
create policy "routes add" on routes for insert to authenticated with check (is_upravnik());
create policy "routes del" on routes for delete to authenticated using (is_upravnik());

-- vođa direktno može upisati samo ULAZ; izlaz ide isključivo preko funkcije izlaz()
drop policy if exists "mov add" on movements; drop policy if exists "mov del" on movements;
create policy "mov add" on movements for insert to authenticated with check (can_plant(plant_id) and kind='promet' and qty_in>0);
create policy "mov del" on movements for delete to authenticated using (can_plant(plant_id) and kind='promet');

create or replace view v_stock with (security_invoker=true) as
select m.plant_id, p.name plant, m.customer_id, c.name customer, m.product_id, pr.name product, m.serija,
  coalesce(sum(m.qty_in) filter (where m.kind in ('promet','pogon')),0)::int qty_in,
  coalesce(sum(m.qty_out) filter (where m.kind in ('promet','pogon','otprema')),0)::int qty_out,
  sum(m.qty_in-m.qty_out)::int stanje,
  max(m.date) filter (where m.kind in ('promet','pogon') and m.qty_in>0) last_in,
  max(m.date) filter (where m.kind in ('promet','pogon','otprema') and m.qty_out>0) last_out
from movements m join plants p on p.id=m.plant_id join customers c on c.id=m.customer_id join products pr on pr.id=m.product_id
where not p.is_main
group by 1,2,3,4,5,6,7;

create or replace function transfer_stock(p_plant uuid, p_product uuid, p_serija text, p_from uuid, p_to uuid, p_qty int default null)
returns void language plpgsql security definer set search_path=public as $$
declare st int; q int; fn text; tn text; tid uuid := gen_random_uuid();
begin
  if not can_plant(p_plant) then raise exception 'Nemate pravo'; end if;
  if p_from=p_to then raise exception 'Odaberite drugog kupca'; end if;
  select coalesce(sum(qty_in-qty_out),0) into st from movements where plant_id=p_plant and product_id=p_product and serija=p_serija and customer_id=p_from;
  q := coalesce(p_qty, st);
  if q<=0 or q>st then raise exception 'Neispravna količina (stanje: %)', st; end if;
  select name into fn from customers where id=p_from; select name into tn from customers where id=p_to;
  insert into movements(plant_id,customer_id,product_id,serija,qty_out,note,kind,transfer_id) values(p_plant,p_from,p_product,p_serija,q,'Prebačeno na: '||tn,'prebacivanje',tid);
  insert into movements(plant_id,customer_id,product_id,serija,qty_in,note,kind,transfer_id) values(p_plant,p_to,p_product,p_serija,q,'Prebačeno sa: '||fn,'prebacivanje',tid);
end $$;

drop function if exists transfer_plants(uuid,uuid,uuid,uuid,text,int);

-- IZLAZ: iz pogona u drugi pogon (skida se ovdje, dodaje tamo) ili u glavni magacin (samo skida, stanje glavnog se ne vodi). Samo dozvoljene rute.
create or replace function izlaz(p_plant uuid, p_to uuid, p_customer uuid, p_product uuid, p_serija text, p_qty int,
  p_date date default current_date, p_note text default null)
returns void language plpgsql security definer set search_path=public as $$
declare st int; fn text; tn text; mn boolean; tid uuid := gen_random_uuid(); s text := coalesce(p_serija,'');
begin
  if not can_plant(p_plant) then raise exception 'Nemate pravo na ovaj pogon'; end if;
  if not exists(select 1 from routes where from_plant=p_plant and to_plant=p_to) then raise exception 'Ta ruta nije dozvoljena'; end if;
  if p_qty is null or p_qty<=0 then raise exception 'Neispravna količina'; end if;
  select coalesce(sum(qty_in-qty_out),0) into st from movements where plant_id=p_plant and customer_id=p_customer and product_id=p_product and serija=s;
  if p_qty>st then raise exception 'Količina je veća od stanja (stanje: %)', st; end if;
  select name into fn from plants where id=p_plant; select name,is_main into tn,mn from plants where id=p_to;
  if mn then
    insert into movements(date,plant_id,customer_id,product_id,serija,qty_out,note,kind,transfer_id)
    values(p_date,p_plant,p_customer,p_product,s,p_qty,concat_ws(' · ','Otprema: '||tn,nullif(p_note,'')),'otprema',tid);
  else
    insert into movements(date,plant_id,customer_id,product_id,serija,qty_out,note,kind,transfer_id)
    values(p_date,p_plant,p_customer,p_product,s,p_qty,concat_ws(' · ','Prebačeno u pogon: '||tn,nullif(p_note,'')),'pogon',tid);
    insert into movements(date,plant_id,customer_id,product_id,serija,qty_in,note,kind,transfer_id)
    values(p_date,p_to,p_customer,p_product,s,p_qty,concat_ws(' · ','Primljeno iz pogona: '||fn,nullif(p_note,'')),'pogon',tid);
  end if;
end $$;

-- KOREKCIJE (samo upravnik): ispravka količine/datuma i brisanje; kod prebacivanja se mijenjaju obje strane
create or replace function ispravi_unos(p_id uuid, p_qty int, p_date date) returns void
language plpgsql security definer set search_path=public as $$
declare r movements%rowtype;
begin
  if not is_upravnik() then raise exception 'Samo upravnik može ispravljati'; end if;
  if p_qty is null or p_qty<=0 then raise exception 'Neispravna količina'; end if;
  select * into r from movements where id=p_id; if not found then raise exception 'Unos ne postoji'; end if;
  if r.kind<>'promet' and r.transfer_id is null then raise exception 'Staro prebacivanje bez veze s parom – ispravite ručno'; end if;
  update movements set qty_in=case when qty_in>0 then p_qty else 0 end, qty_out=case when qty_out>0 then p_qty else 0 end,
    date=coalesce(p_date,date),
    note=concat_ws(' · ',note,'ispravio upravnik '||to_char(current_date,'DD.MM.YYYY')||', bilo '||greatest(r.qty_in,r.qty_out))
  where id=p_id or (r.transfer_id is not null and transfer_id=r.transfer_id);
end $$;

create or replace function obrisi_unos(p_id uuid) returns void
language plpgsql security definer set search_path=public as $$
declare r movements%rowtype;
begin
  if not is_upravnik() then raise exception 'Samo upravnik može brisati'; end if;
  select * into r from movements where id=p_id; if not found then raise exception 'Unos ne postoji'; end if;
  if r.kind<>'promet' and r.transfer_id is null then raise exception 'Staro prebacivanje bez veze s parom – obrišite ručno'; end if;
  delete from movements where id=p_id or (r.transfer_id is not null and transfer_id=r.transfer_id);
end $$;
