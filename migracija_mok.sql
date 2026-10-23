-- MOK: proizvodnja čahura (na čekanju / prekontrolisano), škart i izlaz na Laboraciju
-- Pokreni kao rola "postgres" u Supabase -> SQL Editor.
-- Sigurno je pokrenuti više puta (idempotentno).

-- ===== 1) Status proizvodnje na svakom unosu =====
-- 'cekanje'  = proizvedeno, čeka kontrolu (ne može na izlaz)
-- 'kontrola' = prekontrolisano, spremno za izlaz (i svi stari/normalni unosi)
alter table movements add column if not exists status text not null default 'kontrola';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'movements_status_check' and conrelid = 'movements'::regclass) then
    alter table movements add constraint movements_status_check check (status in ('cekanje','kontrola'));
  end if;
end $$;
update movements set status = 'kontrola' where status is null;

-- ===== 1b) Kupac nije obavezan; MOK ne veže količinu za kupca =====
alter table movements alter column customer_id drop not null;
alter table plants add column if not exists tracks_customer boolean not null default true;
update plants set tracks_customer = false where lower(name) = 'pogon mok';

-- Oznake kupaca po proizvodu (više kupaca, ista količina – ništa se ne duplira)
create table if not exists stock_customers(
  plant_id uuid not null references plants(id) on delete cascade,
  product_id uuid not null references products(id) on delete cascade,
  customer_id uuid not null references customers(id) on delete cascade,
  primary key (plant_id, product_id, customer_id)
);
alter table stock_customers enable row level security;
drop policy if exists "stock_customers read" on stock_customers;
create policy "stock_customers read" on stock_customers for select to authenticated
  using (can_plant(plant_id) or is_upravnik());
drop policy if exists "stock_customers add" on stock_customers;
create policy "stock_customers add" on stock_customers for insert to authenticated
  with check (can_plant(plant_id) or is_upravnik());
drop policy if exists "stock_customers del" on stock_customers;
create policy "stock_customers del" on stock_customers for delete to authenticated
  using (can_plant(plant_id) or is_upravnik());
grant select, insert, delete on stock_customers to authenticated;

-- Postojeće kupce iz MOK-a prebaci u oznake (bez novih količina)
insert into stock_customers(plant_id, product_id, customer_id)
select distinct m.plant_id, m.product_id, m.customer_id
from movements m join plants p on p.id = m.plant_id
where not p.tracks_customer and m.customer_id is not null
  and m.qty_in > 0 and m.kind in ('promet','pogon')
on conflict do nothing;

-- ===== 2) Pogon MOK šalje na Laboraciju (Glavni magacin više nije odredište MOK-a) =====
insert into plants(name) values ('Laboracija') on conflict ((lower(name))) do nothing;
update plants set dest_for = null where is_main;
update plants set dest_for = (select id from plants where lower(name) = 'pogon mok')
 where lower(name) = 'laboracija';

-- ===== 3) Stanje: obični magacini po kupcu, Pogon MOK po proizvodu (bez kupca) =====
create or replace view v_stock with (security_invoker=true) as
-- Glavni magacin i drugi magacini: stanje se prati po kupcu
select m.plant_id, p.name plant, m.customer_id, coalesce(c.name,'') customer, m.product_id, pr.name product, m.serija,
  coalesce(sum(m.qty_in) filter (where m.kind in ('promet','pogon')),0)::int qty_in,
  coalesce(sum(m.qty_out) filter (where m.kind in ('promet','pogon','otprema','izlaz','skart')),0)::int qty_out,
  sum(m.qty_in-m.qty_out)::int stanje,
  max(m.date) filter (where m.kind in ('promet','pogon') and m.qty_in>0) last_in,
  max(m.date) filter (where m.kind in ('promet','pogon','otprema','izlaz') and m.qty_out>0) last_out,
  m.status
from movements m join plants p on p.id=m.plant_id left join customers c on c.id=m.customer_id join products pr on pr.id=m.product_id
where p.tracks_customer
group by 1,2,3,4,5,6,7,m.status
union all
-- Pogon MOK: stanje po proizvodu i seriji, kupci su samo oznake
select m.plant_id, p.name plant, null::uuid, ''::text, m.product_id, pr.name product, m.serija,
  coalesce(sum(m.qty_in) filter (where m.kind in ('promet','pogon')),0)::int qty_in,
  coalesce(sum(m.qty_out) filter (where m.kind in ('promet','pogon','otprema','izlaz','skart')),0)::int qty_out,
  sum(m.qty_in-m.qty_out)::int stanje,
  max(m.date) filter (where m.kind in ('promet','pogon') and m.qty_in>0) last_in,
  max(m.date) filter (where m.kind in ('promet','pogon','otprema','izlaz') and m.qty_out>0) last_out,
  m.status
from movements m join plants p on p.id=m.plant_id join products pr on pr.id=m.product_id
where not p.tracks_customer
group by 1,2,3,4,5,6,7,m.status;

-- ===== 4) Izlaz je dozvoljen samo za prekontrolisano (status = 'kontrola') =====
-- prvo skini sve stare verzije funkcija da ne ostane dvosmisleno preklapanje
do $$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p
           where p.proname in ('izlaz','transfer_stock') and p.pronamespace='public'::regnamespace
  loop
    execute 'drop function '||f;
  end loop;
end $$;

create or replace function izlaz(p_plant uuid, p_customer uuid, p_product uuid, p_serija text, p_qty int, p_to uuid,
  p_date date default current_date, p_note text default null)
returns void language plpgsql security definer set search_path=public as $$
declare st int; s text := coalesce(p_serija,''); tn text; tc boolean;
begin
  if not can_plant(p_plant) then raise exception 'Nemate pravo na ovaj magacin'; end if;
  if p_qty is null or p_qty<=0 then raise exception 'Neispravna količina'; end if;
  select name into tn from plants where id=p_to;
  if tn is null then raise exception 'Nepoznat pogon / odredište'; end if;
  select tracks_customer into tc from plants where id=p_plant;
  if tc is null then raise exception 'Nepoznat magacin'; end if;
  -- MOK ne veže stanje za kupca: kupac se ovdje samo evidentira ako je izabran
  select coalesce(sum(qty_in-qty_out),0) into st from movements
    where plant_id=p_plant and product_id=p_product and serija=s
      and status='kontrola'
      and (not tc or customer_id=p_customer);
  if p_qty>st then raise exception 'Količina je veća od prekontrolisanog stanja (stanje: %)', st; end if;
  insert into movements(date,plant_id,customer_id,product_id,serija,qty_out,note,kind,transfer_id,to_plant,status)
  values(p_date,p_plant,p_customer,p_product,s,p_qty,concat_ws(' · ','Izlaz u pogon: '||tn,nullif(p_note,'')),'izlaz',gen_random_uuid(),p_to,'kontrola');
end $$;

-- ===== 5) Prekontroliši: upiši škart (ako ga je bilo), ostatak postaje spreman za izlaz =====
create or replace function prekontrolisi(p_plant uuid, p_customer uuid, p_product uuid, p_serija text,
  p_skart int default 0, p_date date default current_date)
returns void language plpgsql security definer set search_path=public as $$
declare s text := coalesce(p_serija,''); st int; dozvoljeno boolean; tc boolean;
begin
  select exists(select 1 from profiles where id=auth.uid() and role in ('upravnik','admin')) into dozvoljeno;
  if not (dozvoljeno or can_plant(p_plant)) then raise exception 'Nemate pravo na ovaj magacin'; end if;
  if p_skart is null or p_skart < 0 then raise exception 'Neispravan škart'; end if;
  select tracks_customer into tc from plants where id=p_plant;
  if tc is null then raise exception 'Nepoznat magacin'; end if;

  select coalesce(sum(qty_in-qty_out),0) into st from movements
    where plant_id=p_plant and product_id=p_product and serija=s and status='cekanje'
      and (not tc or customer_id=p_customer);
  if st <= 0 then raise exception 'Nema proizvodnje na čekanju za ovaj artikal'; end if;
  if p_skart > st then raise exception 'Škart (%) je veći od količine na čekanju (%)', p_skart, st; end if;

  update movements set status='kontrola'
    where plant_id=p_plant and product_id=p_product and serija=s and status='cekanje'
      and (not tc or customer_id=p_customer);

  if p_skart > 0 then
    insert into movements(date,plant_id,customer_id,product_id,serija,qty_out,note,kind,status)
    values(coalesce(p_date,current_date),p_plant,p_customer,p_product,s,p_skart,'Škart pri kontroli','skart','kontrola');
  end if;
end $$;

-- ===== 6) Prebacivanje na drugog kupca samo sa prekontrolisanog stanja =====
create or replace function transfer_stock(p_plant uuid, p_product uuid, p_serija text, p_from uuid, p_to uuid, p_qty int default null)
returns void language plpgsql security definer set search_path=public as $$
declare st int; q int; fn text; tn text; tid uuid := gen_random_uuid();
begin
  if not can_plant(p_plant) then raise exception 'Nemate pravo'; end if;
  if p_from=p_to then raise exception 'Odaberite drugog kupca'; end if;
  select coalesce(sum(qty_in-qty_out),0) into st from movements
    where plant_id=p_plant and product_id=p_product and serija=p_serija and customer_id=p_from and status='kontrola';
  q := coalesce(p_qty, st);
  if q<=0 or q>st then raise exception 'Neispravna količina (stanje: %)', st; end if;
  select name into fn from customers where id=p_from; select name into tn from customers where id=p_to;
  insert into movements(plant_id,customer_id,product_id,serija,qty_out,note,kind,transfer_id,status) values(p_plant,p_from,p_product,p_serija,q,'Prebačeno na: '||tn,'prebacivanje',tid,'kontrola');
  insert into movements(plant_id,customer_id,product_id,serija,qty_in,note,kind,transfer_id,status) values(p_plant,p_to,p_product,p_serija,q,'Prebačeno sa: '||fn,'prebacivanje',tid,'kontrola');
end $$;

notify pgrst, 'reload schema';

-- Ako želiš da postojeće stanje Pogona MOK počne kao "na čekanju kontrole",
-- otkomentariši sljedeću liniju prije pokretanja:
-- update movements set status='cekanje'
--  where plant_id=(select id from plants where lower(name)='pogon mok')
--    and status='kontrola' and kind in ('promet','pogon') and qty_in>0;

-- ===== Provjere =====
select p.name, p.is_store, p.tracks_customer, d.name as dest_for
from plants p left join plants d on d.id = p.dest_for
order by p.is_store desc, p.name;

select plant_id, product, customer, serija, status, stanje
from v_stock where status = 'cekanje' order by product, serija, customer;

select sc.plant_id, p.name as plant, pr.name as product, c.name as customer
from stock_customers sc
join plants p on p.id = sc.plant_id
join products pr on pr.id = sc.product_id
join customers c on c.id = sc.customer_id
order by p.name, pr.name, c.name;
