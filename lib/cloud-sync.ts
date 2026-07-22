import { supabase, isSupabaseConfigured } from "./supabase";

/**
 * Two-way cloud sync.
 *
 * The whole app already uses the localStorage key `tech_candidates_admin`
 * (an array of candidate objects) as its in-browser source of truth, and both
 * the candidate HQ and the admin already react to `storage` events + polling.
 *
 * This layer mirrors that array to a Supabase `candidates` table and back:
 *   • on load  → pull cloud rows, merge into localStorage (migrates existing data up)
 *   • on change → push localStorage up (debounced)
 *   • realtime → cloud changes flow back into localStorage, and the app's
 *                existing listeners re-render automatically.
 *
 * Nothing in the page/admin business logic has to change. If Supabase isn't
 * configured, this is a no-op and the app stays purely local.
 */

const KEY = "tech_candidates_admin";
type Cand = Record<string, any>;

// ---- object <-> row mapping (readable columns in the Supabase table) ----
function rowFromCand(c: Cand) {
  return {
    email: String(c.email || "").toLowerCase(),
    app_id: c.id ?? null,
    player_no: c.playerNo ?? null,
    name: c.name ?? "",
    branch: c.branch ?? "",
    section: c.section ?? "",
    phone: c.phone ?? "",
    college_id: c.collegeId ?? "",
    domains: c.domains ?? [],
    answers: c.answers ?? {},
    pin_hash: c.pinHash ?? "",
    stage_idx: c.stageIdx ?? 1,
    submissions: c.submissions ?? {},
    submission_link: c.submissionLink ?? null,
    task_score: c.taskScore ?? null,
    interview_score: c.interviewScore ?? null,
    rejected: !!c.rejected,
    rejected_at_stage: c.rejectedAtStage ?? null,
    rejection_feedback: c.rejectionFeedback ?? null,
    notes: c.notes ?? null,
    client_updated_at: Date.now(),
  };
}

function candFromRow(r: Cand): Cand {
  return {
    id: r.app_id || `cand-${r.email}`,
    playerNo: r.player_no ?? 1001,
    name: r.name || "",
    email: r.email || "",
    branch: r.branch || "",
    section: r.section || "",
    phone: r.phone || "",
    collegeId: r.college_id || "",
    domains: r.domains || [],
    answers: r.answers || {},
    pinHash: r.pin_hash || "",
    stageIdx: r.stage_idx ?? 1,
    submissions: r.submissions || {},
    submissionLink: r.submission_link || undefined,
    taskScore: r.task_score ?? undefined,
    interviewScore: r.interview_score ?? undefined,
    rejected: !!r.rejected,
    rejectedAtStage: r.rejected_at_stage ?? undefined,
    rejectionFeedback: r.rejection_feedback ?? undefined,
    notes: r.notes ?? undefined,
    updatedAt: "SYNCED",
  };
}

function readLocal(): Cand[] {
  try {
    return JSON.parse(localStorage.getItem(KEY) || "[]");
  } catch {
    return [];
  }
}

function writeLocal(list: Cand[]) {
  localStorage.setItem(KEY, JSON.stringify(list));
  // storage events don't fire in the same tab — nudge the app's listeners.
  try {
    window.dispatchEvent(new StorageEvent("storage", { key: KEY }));
  } catch {
    /* older browsers */
  }
}

// Merge cloud rows with any local-only (not-yet-pushed) rows, cloud wins.
function merge(cloud: Cand[], local: Cand[]): Cand[] {
  const byEmail: Record<string, Cand> = {};
  cloud.forEach((c) => { byEmail[String(c.email).toLowerCase()] = c; });
  local.forEach((c) => {
    const k = String(c.email || "").toLowerCase();
    if (k && !byEmail[k]) byEmail[k] = c;
  });
  return Object.values(byEmail);
}

let lastHash = "";
let started = false;

export function initCloudSync(): void {
  if (started || !isSupabaseConfigured || !supabase || typeof window === "undefined") return;
  started = true;
  const sb = supabase;

  const pullMerge = async () => {
    const { data, error } = await sb.from("candidates").select("*");
    if (error || !data) return;
    const merged = merge(data.map(candFromRow), readLocal());
    const h = JSON.stringify(merged);
    if (h !== JSON.stringify(readLocal())) writeLocal(merged);
    lastHash = h;
  };

  const pushLocal = async () => {
    const local = readLocal();
    const h = JSON.stringify(local);
    if (h === lastHash) return;
    lastHash = h;
    if (!local.length) return;
    const rows = local.map(rowFromCand);
    await sb.from("candidates").upsert(rows, { onConflict: "email" });
  };

  // 1) initial pull (migrates any existing local data up), then continuous push
  pullMerge().then(pushLocal);

  const iv = window.setInterval(pushLocal, 2500);
  const onStorage = (e: StorageEvent) => { if (e.key === KEY) pushLocal(); };
  window.addEventListener("storage", onStorage);

  // 2) realtime: any cloud change → refresh local
  sb.channel("candidates-sync")
    .on("postgres_changes", { event: "*", schema: "public", table: "candidates" }, pullMerge)
    .subscribe();

  window.addEventListener("beforeunload", () => {
    window.clearInterval(iv);
    window.removeEventListener("storage", onStorage);
  });
}
