-- Gardens: regional plant picks on the job, and a shared cache of plant product shots.

alter table public.generation_jobs
  add column if not exists kind text not null default 'interior' check (kind in ('interior', 'garden')),
  add column if not exists plants jsonb,
  add column if not exists design_notes text;

-- One product shot per plant, reused across users. Written only by edge functions.
create table if not exists public.plant_images (
  name_key text primary key,
  plant_name text not null,
  image_url text not null,
  created_at timestamptz not null default now()
);
alter table public.plant_images enable row level security;

insert into storage.buckets (id, name, public, allowed_mime_types)
values ('plant-images', 'plant-images', true, array['image/jpeg'])
on conflict (id) do nothing;
