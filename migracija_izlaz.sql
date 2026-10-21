-- BRZI IZLAZ IZ MAGACINA (bez ruta) — pokreni kao rola postgres u Supabase → SQL Editor
-- Poslije ovoga: vođa na "Izlaz" bira pogon + kupca, izlaz skida količinu sa stanja,
-- a transakcija ostaje u Historiji.

-- 1) Stara funkcija je tražila rutu i odredište – sklanjamo je
drop function if exists izlaz(uuid, uuid, uuid, uuid, text, int, date, text);

-- 2) Nova funkcija: samo skida količinu sa stanja (pogon + kupac + artikal + serija)
create or replace function izlaz(p_plant uuid, p_customer uuid, p_product uuid, p_serija text, p_qty int,
  p_date date default current_date, p_note text default null)
returns void language plpgsql security definer set search_path=public as $$
declare st int; s text := coalesce(p_serija,'');
begin
  if not can_plant(p_plant) then raise exception 'Nemate pravo na ovaj pogon'; end if;
  if p_qty is null or p_qty<=0 then raise exception 'Neispravna količina'; end if;
  select coalesce(sum(qty_in-qty_out),0) into st from movements
    where plant_id=p_plant and customer_id=p_customer and product_id=p_product and serija=s;
  if p_qty>st then raise exception 'Količina je veća od stanja (stanje: %)', st; end if;
  insert into movements(date,plant_id,customer_id,product_id,serija,qty_out,note,kind,transfer_id)
  values(p_date,p_plant,p_customer,p_product,s,p_qty,nullif(p_note,''),'izlaz',gen_random_uuid());
end $$;

-- 3) Stanje mora da uračuna novi tip 'izlaz'
create or replace view v_stock with (security_invoker=true) as
select m.plant_id, p.name plant, m.customer_id, c.name customer, m.product_id, pr.name product, m.serija,
  coalesce(sum(m.qty_in) filter (where m.kind in ('promet','pogon')),0)::int qty_in,
  coalesce(sum(m.qty_out) filter (where m.kind in ('promet','pogon','otprema','izlaz')),0)::int qty_out,
  sum(m.qty_in-m.qty_out)::int stanje,
  max(m.date) filter (where m.kind in ('promet','pogon') and m.qty_in>0) last_in,
  max(m.date) filter (where m.kind in ('promet','pogon','otprema','izlaz') and m.qty_out>0) last_out
from movements m join plants p on p.id=m.plant_id join customers c on c.id=m.customer_id join products pr on pr.id=m.product_id
where not p.is_main
group by 1,2,3,4,5,6,7;

-- Provjera: treba da vrati vrste kretanja (promet, pogon, otprema, izlaz)
select kind, count(*) from movements group by kind order by kind;
