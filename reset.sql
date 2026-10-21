-- BRISANJE SVEGA (pokreni kao rola postgres!). Nakon toga pokreni schema.sql
drop view if exists v_stock;
drop trigger if exists on_auth_user_created on auth.users;
drop table if exists movements, user_plants, customers, products, profiles, plants cascade;
drop function if exists handle_new_user(), is_upravnik(), my_plant(), can_plant(uuid),
  transfer_stock(uuid,uuid,uuid,uuid,int), transfer_stock(uuid,uuid,text,uuid,uuid,int), transfer_plants(uuid,uuid,uuid,uuid,text,int);
delete from auth.users where email in ('o.senad@pobjeda.com','k.belmin@pobjeda.com');
