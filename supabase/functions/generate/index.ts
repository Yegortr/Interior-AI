// Reroom: starts an interior redesign.
//
// 1. Verifies the caller (anonymous Supabase users included).
// 2. Enforces a per-user daily limit.
// 3. Creates a `generation_jobs` row and returns its id immediately.
// 4. In the background (EdgeRuntime.waitUntil) calls Runware with a signed URL of the source photo
//    and stores the resulting image URL on the job. The app polls the job and downloads the image.
//
// Gardens: before rendering, an LLM (Gemini through Runware's textInference) looks at the photo
// and the user's region/season and picks plants that thrive there; each plant gets a cached
// product shot (quotes stripped from names so the model never paints lettering). Plants are
// written to the job as soon as they're chosen.
//
// Everything goes through ONE provider: Runware (images + LLM).
// Secrets: RUNWARE_API_KEY (required); optional RUNWARE_MODEL, RUNWARE_PLANT_MODEL,
// RUNWARE_LLM_MODEL, DAILY_LIMIT.
import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void };

const RUNWARE_URL = "https://api.runware.ai/v1";
// Google Nano Banana (Gemini image) on Runware — an editing model that keeps room geometry well.
const MODEL = Deno.env.get("RUNWARE_MODEL") ?? "google:4@1";
const DAILY_LIMIT = Number(Deno.env.get("DAILY_LIMIT") ?? "30");
// Fast, cheap text-to-image model for plant product shots.
const PLANT_MODEL = Deno.env.get("RUNWARE_PLANT_MODEL") ?? "runware:100@1";
// Multimodal LLM on Runware used for plant picks.
const LLM_MODEL = Deno.env.get("RUNWARE_LLM_MODEL") ?? "google:gemini@3.1-flash-lite";
const PLANT_SUFFIX = "No text, no labels, no watermarks, professional botanical product photography on solid background";

// Sizes accepted by the Gemini image models; others take any multiple of 64.
const GOOGLE_SIZES: Array<[number, number]> = [
  [1024, 1024], [832, 1248], [1248, 832], [864, 1184], [1184, 864],
  [896, 1152], [1152, 896], [768, 1344], [1344, 768], [1536, 672],
];

interface GardenContext {
  location: { name: string; latitude?: number | null; longitude?: number | null };
  month: number;
  sunlight: string;
  style: string;
  maintenance: string;
  petSafe: boolean;
  hardscaping: string[];
  notes: string;
}

interface GenerateBody {
  imagePath: string;
  prompt: string;
  aspectRatio?: string;
  width: number;
  height: number;
  clientRequestId?: string;
  kind?: "interior" | "garden";
  garden?: GardenContext | null;
}

interface Plant {
  name: string;
  scientificName?: string;
  reason?: string;
  sun?: string;
  water?: string;
  careLevel?: string;
  petSafe?: boolean;
  hardiness?: string;
  height?: string;
  bloomSeason?: string;
  careTips?: string[];
  imageUrl?: string;
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
  const kind = body.kind === "garden" ? "garden" : "interior";
  const { data: job, error: insertError } = await admin
    .from("generation_jobs")
    .insert({
      user_id: user.id,
      kind,
      status: "queued",
      prompt,
      image_path: body.imagePath,
      client_request_id: body.clientRequestId ?? null,
      params: { model: MODEL, width, height, aspectRatio: body.aspectRatio ?? null, garden: body.garden ?? null },
    })
    .select("id")
    .single();
  if (insertError || !job) return json({ error: "Couldn't start the generation." }, 500);

  const garden = kind === "garden" ? body.garden ?? null : null;
  EdgeRuntime.waitUntil(runJob(admin, job.id, { prompt, width, height, imageUrl: signed.signedUrl, garden }));
  return json({ jobId: job.id });
});

async function runJob(
  admin: SupabaseClient,
  jobId: string,
  input: { prompt: string; width: number; height: number; imageUrl: string; garden: GardenContext | null },
) {
  const update = (fields: Record<string, unknown>) =>
    admin.from("generation_jobs").update({ ...fields, updated_at: new Date().toISOString() }).eq("id", jobId);

  await update({ status: "processing" });
  try {
    let prompt = input.prompt;
    let plants: Plant[] = [];

    if (input.garden) {
      try {
        const plan = await recommendPlants(input.imageUrl, input.garden);
        plants = plan.plants;
        if (plan.imagePrompt) prompt = plan.imagePrompt;
        if (plants.length) {
          prompt += ` Planting includes: ${plants.map((p) => sanitizePlantName(p.name)).join(", ")}.`;
        }
        prompt += " No text, no labels, no watermark.";
        await update({ plants, design_notes: plan.designNotes ?? null });
      } catch (error) {
        // Plant picks are a bonus; the redesign still renders from the client prompt.
        console.error(`job ${jobId}: plant recommendations failed`, error);
      }
    }

    const [imageUrl] = await Promise.all([
      runwareImage({ model: MODEL, prompt, width: input.width, height: input.height, referenceImages: [input.imageUrl] }),
      plants.length
        ? attachPlantImages(admin, plants).then((withImages) => update({ plants: withImages }))
        : Promise.resolve(),
    ]);
    await update({ status: "completed", result_url: imageUrl, error_message: null });
  } catch (error) {
    console.error(`job ${jobId} failed`, error);
    await update({ status: "failed", error_message: friendlyError(error) });
  }
}

/** Sends one task to Runware and returns its first result object. */
async function runware(task: Record<string, unknown>): Promise<Record<string, unknown>> {
  const response = await fetch(RUNWARE_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${Deno.env.get("RUNWARE_API_KEY")}`,
    },
    body: JSON.stringify([{ taskUUID: crypto.randomUUID(), ...task }]),
  });
  const payload = await response.json().catch(() => ({}));
  const runwareError = payload?.errors?.[0]?.message ?? payload?.error;
  if (!response.ok || runwareError) throw new Error(runwareError ?? `Runware HTTP ${response.status}`);
  const result = (payload?.data ?? [])[0];
  if (!result) throw new Error("Runware returned no result.");
  return result;
}

async function runwareImage(task: {
  model: string;
  prompt: string;
  width: number;
  height: number;
  referenceImages?: string[];
}): Promise<string> {
  const result = await runware({
      taskType: "imageInference",
      taskUUID: crypto.randomUUID(),
      model: task.model,
      positivePrompt: task.prompt,
      width: task.width,
      height: task.height,
      ...(task.referenceImages?.length ? { inputs: { referenceImages: task.referenceImages } } : {}),
      numberResults: 1,
      outputType: "URL",
      outputFormat: "JPEG",
  });
  const url = result.imageURL;
  if (typeof url !== "string") throw new Error("The model returned no image.");
  return url;
}

// ---------------------------------------------------------------------------------------------
// Regional plant recommendations (Gemini, multimodal)

async function recommendPlants(
  imageUrl: string,
  garden: GardenContext,
): Promise<{ plants: Plant[]; designNotes?: string; imagePrompt?: string }> {
  const latitude = garden.location.latitude;
  const hemisphere = latitude == null ? "unknown" : latitude >= 0 ? "northern" : "southern";
  const month = new Date(2000, Math.max(0, Math.min(11, (garden.month || 1) - 1)), 1)
    .toLocaleString("en-US", { month: "long" });

  const instructions = `You are a senior landscape designer and horticulturist.
Look at the photo of this outdoor space and recommend 6 to 8 plants for it.

Location: ${garden.location.name}${latitude != null ? ` (lat ${latitude}, lon ${garden.location.longitude})` : ""}
Hemisphere: ${hemisphere}. Current month: ${month}.
Sunlight: ${garden.sunlight}. Style: ${garden.style}. Maintenance: ${garden.maintenance}.
Pet-safe only: ${garden.petSafe ? "yes — exclude anything toxic to cats or dogs" : "no"}.
Hardscaping wanted: ${garden.hardscaping.length ? garden.hardscaping.join(", ") : "none"}.
Wishes: ${garden.notes || "none"}.

Rules:
- Only plants that reliably thrive in this location's climate (hardiness zone, rainfall, heat, frost).
  Prefer native or well-adapted species; avoid invasive species for this region.
- Match the sunlight, style and maintenance level. Mix structure, seasonal color and ground cover.
- "reason" explains in one sentence why it suits THIS location and space.
- Short values: sun ("Full sun"), water ("Moderate"), careLevel ("Easy"), hardiness ("USDA 6–9" or similar),
  height ("60–90 cm"), bloomSeason ("Jun–Aug" or "Evergreen"). 2–3 practical careTips each.
- imagePrompt: one paragraph for an image model to redesign THIS photo as the new garden, featuring these
  plants placed sensibly, keeping the same camera angle, boundaries, house and fences. Photorealistic.
- designNotes: 2–3 sentences summarising the design idea for the owner.
Respond with ONLY a JSON object, no markdown, in exactly this shape:
{"designNotes": string, "imagePrompt": string, "plants": [{"name": string, "scientificName": string,
 "reason": string, "sun": string, "water": string, "careLevel": string, "petSafe": boolean,
 "hardiness": string, "height": string, "bloomSeason": string, "careTips": [string]}]}`;

  const result = await runware({
    taskType: "textInference",
    model: LLM_MODEL,
    messages: [{ role: "user", content: instructions }],
    inputs: { images: [imageUrl] },
    settings: { maxTokens: 4096, temperature: 0.4 },
  });
  const plan = parseJSONObject(String(result.text ?? ""));
  const plants: Plant[] = (Array.isArray(plan.plants) ? plan.plants : [])
    .filter((p: Plant) => typeof p?.name === "string" && p.name.trim())
    .slice(0, 8);
  // Respect the pet-safe answer even if the model slips.
  const safe = garden.petSafe ? plants.filter((p) => p.petSafe !== false) : plants;
  return {
    plants: safe,
    designNotes: typeof plan.designNotes === "string" ? plan.designNotes : undefined,
    imagePrompt: typeof plan.imagePrompt === "string" ? plan.imagePrompt : undefined,
  };
}

/** LLMs sometimes wrap JSON in prose or ``` fences; take the outermost object. */
export function parseJSONObject(text: string): Record<string, any> {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end <= start) throw new Error("LLM returned no JSON");
  return JSON.parse(text.slice(start, end + 1));
}

// ---------------------------------------------------------------------------------------------
// Plant product shots (cached across users)

/** Strips every kind of quote so diffusion models don't render names as lettering: Echeveria 'Lola' → Echeveria Lola. */
export function sanitizePlantName(name: string): string {
  return name.replace(/['"`´‘’‚‛“”„‟«»‹›]/g, "").replace(/\s+/g, " ").trim();
}

function plantKey(name: string): string {
  return sanitizePlantName(name).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

async function attachPlantImages(admin: SupabaseClient, plants: Plant[]): Promise<Plant[]> {
  const keys = plants.map((p) => plantKey(p.name));
  const { data: cached } = await admin.from("plant_images").select("name_key,image_url").in("name_key", keys);
  const known = new Map<string, string>((cached ?? []).map((row: { name_key: string; image_url: string }) => [row.name_key, row.image_url]));

  const results = await Promise.allSettled(plants.map(async (plant, index) => {
    const key = keys[index];
    if (known.has(key)) return known.get(key)!;
    const common = sanitizePlantName(plant.name);
    const scientific = plant.scientificName ? sanitizePlantName(plant.scientificName) : "";
    const subject = scientific && scientific.toLowerCase() !== common.toLowerCase() ? `${common} (${scientific})` : common;
    const generated = await runwareImage({
      model: PLANT_MODEL,
      prompt: `${subject}, a single healthy specimen in a plain matte pot, studio lighting, true-to-life foliage and flowers. ${PLANT_SUFFIX}`,
      width: 768,
      height: 768,
    });
    // Runware URLs are temporary: keep a permanent copy.
    const bytes = new Uint8Array(await (await fetch(generated)).arrayBuffer());
    const path = `${key}.jpg`;
    await admin.storage.from("plant-images").upload(path, bytes, { contentType: "image/jpeg", upsert: true });
    const url = admin.storage.from("plant-images").getPublicUrl(path).data.publicUrl;
    await admin.from("plant_images").upsert({ name_key: key, plant_name: common, image_url: url });
    return url;
  }));

  return plants.map((plant, index) => {
    const result = results[index];
    return result.status === "fulfilled" ? { ...plant, imageUrl: result.value } : plant;
  });
}

function friendlyError(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  if (/safety|nsfw|content/i.test(message)) return "This photo couldn't be processed. Try a different one.";
  return "Generation failed. Please try again.";
}
