"use client";

import { useEffect } from "react";
import { initCloudSync } from "@/lib/cloud-sync";

/**
 * Boots the two-way Supabase sync once for the whole app. Renders nothing.
 * No-op unless NEXT_PUBLIC_SUPABASE_URL / ANON_KEY are set.
 */
export default function CloudSync() {
  useEffect(() => {
    initCloudSync();
  }, []);
  return null;
}
