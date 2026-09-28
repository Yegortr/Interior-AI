// Reroom: starts an interior redesign.
//
// 1. Verifies the caller (anonymous Supabase users included).
// 2. Enforces a per-user daily limit.
// 3. Creates a `generation_jobs` row and returns its id immediately.
// 4. In the background (EdgeRuntime.waitUntil) calls Runware with a signed URL of the source photo
//    and stores the resulting image URL on the job. The app polls the job and downloads the image.
//
// Secrets: RUNWARE_API_KEY (required), RUNWARE_MODEL (optional), DAILY_LIMIT (optional).
import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void };

const RUNWARE_URL = "https://api.runware.ai/v1";
// Google Nano Banana (Gemini image) on Runware — an editing model that keeps room geometry well.
const MODEL = Deno.env.get("RUNWARE_MODEL") ?? "google:4@1";
const DAILY_LIMIT = Number(Deno.env.get("DAILY_LIMIT") ?? "30");

// Sizes accepted by the Gemini image models; others take any multiple of 64.
const GOOGLE_SIZES: Array<[number, number]> = [
  [1024, 1024], [832, 1248], [1248, 832], [864, 1184], [1184, 864],
  [896, 1152], [1152, 896], [768, 1344], [1344, 768], [1536, 672],
];

interface GenerateBody {
  imagePath: string;
  prompt: string;
  aspectRatio?: string;
  width: number;
  height: number;
  clientRequestId?: string;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

function outputSize(width: number, height: number): [number, number] {
  if (!MODEL.startsWith("google:")) {
    const snap = (v: number) => Math.min(2048, Math.max(512, Math.round(v / 64) * 64));
    return [snap(width), snap(height)];
  }
  const ratio = width / height;
  return GOOGLE_SIZES.reduce((best, size) =>
    Math.abs(size[0] / size[1] - ratio) < Math.abs(best[0] / best[1] - ratio) ? size : best
  );
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: { user } } = await admin.auth.getUser(token);
  if (!user) return json({ error: "Please restart the app and try again." }, 401);

  let body: GenerateBody;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid request." }, 400);
  }
  const prompt = String(body.prompt ?? "").trim();
  if (!body.imagePath?.startsWith(`${user.id}/`) || !prompt || prompt.length > 3000) {
    return json({ error: "Invalid request." }, 400);
  }

  const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const { count } = await admin
    .from("generation_jobs")
    .select("id", { count: "exact", head: true })
    .eq("user_id", user.id)
    .gte("created_at", since);
  if ((count ?? 0) >= DAILY_LIMIT) {
    return json({ error: "You've reached today's limit. Please try again tomorrow." }, 429);
  }

  const { data: signed, error: signError } = await admin.storage
    .from("uploads")
    .createSignedUrl(body.imagePath, 60 * 60);
  if (signError || !signed) return json({ error: "Couldn't read the uploaded photo." }, 400);

  const [width, height] = outputSize(Number(body.width) || 1024, Number(body.height) || 1024);
  const { data: job, error: insertError } = await admin
    .from("generation_jobs")
    .insert({
      user_id: user.id,
      status: "queued",
      prompt,
      image_path: body.imagePath,
      client_request_id: body.clientRequestId ?? null,
      params: { model: MODEL, width, height, aspectRatio: body.aspectRatio ?? null },
    })
    .select("id")
    .single();
  if (insertError || !job) return json({ error: "Couldn't start the generation." }, 500);

  EdgeRuntime.waitUntil(runJob(admin, job.id, { prompt, width, height, imageUrl: signed.signedUrl }));
  return json({ jobId: job.id });
});

async function runJob(
  admin: SupabaseClient,
  jobId: string,
  input: { prompt: string; width: number; height: number; imageUrl: string },
) {
  const update = (fields: Record<string, unknown>) =>
    admin.from("generation_jobs").update({ ...fields, updated_at: new Date().toISOString() }).eq("id", jobId);

  await update({ status: "processing" });
  try {
    const response = await fetch(RUNWARE_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${Deno.env.get("RUNWARE_API_KEY")}`,
      },
      body: JSON.stringify([{
        taskType: "imageInference",
        taskUUID: crypto.randomUUID(),
        model: MODEL,
        positivePrompt: input.prompt,
        width: input.width,
        height: input.height,
        referenceImages: [input.imageUrl],
        numberResults: 1,
        outputType: "URL",
        outputFormat: "JPEG",
      }]),
    });
    const payload = await response.json().catch(() => ({}));
    const runwareError = payload?.errors?.[0]?.message ?? payload?.error;
    if (!response.ok || runwareError) throw new Error(runwareError ?? `Runware HTTP ${response.status}`);
    const imageUrl = (payload?.data ?? []).find((item: { imageURL?: string }) => item.imageURL)?.imageURL;
    if (!imageUrl) throw new Error("The model returned no image.");
    await update({ status: "completed", result_url: imageUrl, error_message: null });
  } catch (error) {
    console.error(`job ${jobId} failed`, error);
    await update({ status: "failed", error_message: friendlyError(error) });
  }
}

function friendlyError(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  if (/safety|nsfw|content/i.test(message)) return "This photo couldn't be processed. Try a different one.";
  return "Generation failed. Please try again.";
}
