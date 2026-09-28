-- Reroom backend: a job table the app polls, and a private bucket for source photos.

create table if not exists public.generation_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  status text not null default 'queued'
    check (status in ('queued', 'processing', 'completed', 'failed')),
  prompt text not null,
  params jsonb not null default '{}'::jsonb,
  image_path text,
  result_url text,
  error_message text,
  client_request_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists generation_jobs_user_created_idx
  on public.generation_jobs (user_id, created_at desc);

alter table public.generation_jobs enable row level security;

-- Users (including anonymous ones) can read only their own jobs. Writes happen in the
-- `generate` edge function with the service role.
drop policy if exists "read own jobs" on public.generation_jobs;
create policy "read own jobs" on public.generation_jobs
  for select to authenticated using (user_id = auth.uid());

-- Private bucket for the photos being redesigned. Files live under "<user id>/…".
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('uploads', 'uploads', false, 10485760, array['image/jpeg', 'image/png', 'image/heic'])
on conflict (id) do nothing;

drop policy if exists "upload own photos" on storage.objects;
create policy "upload own photos" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'uploads' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "read own photos" on storage.objects;
create policy "read own photos" on storage.objects
  for select to authenticated
  using (bucket_id = 'uploads' and (storage.foldername(name))[1] = auth.uid()::text);
