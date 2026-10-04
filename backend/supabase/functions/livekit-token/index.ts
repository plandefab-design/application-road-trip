// Moto Road — jeton d'accès au salon vocal d'un groupe (LiveKit).
// Le secret LiveKit reste ici, côté serveur : l'app ne reçoit qu'un jeton de 6 h, valable pour UN salon.
//
// Secrets à définir (Supabase › Edge Functions › Secrets, ou `supabase secrets set`) :
//   LIVEKIT_URL         wss://<ton-projet>.livekit.cloud
//   LIVEKIT_API_KEY     clé API LiveKit
//   LIVEKIT_API_SECRET  secret API LiveKit
import { createClient } from "jsr:@supabase/supabase-js@2";
import { AccessToken } from "npm:livekit-server-sdk@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function reply(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "method not allowed" }, 405);

  const url = Deno.env.get("LIVEKIT_URL");
  const key = Deno.env.get("LIVEKIT_API_KEY");
  const secret = Deno.env.get("LIVEKIT_API_SECRET");
  if (!url || !key || !secret) return reply({ error: "voice not configured" }, 503);

  // Everything below runs as the caller: row-level security decides what he may see.
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: auth } = await supabase.auth.getUser();
  const user = auth?.user;
  if (!user) return reply({ error: "unauthenticated" }, 401);

  let groupId = "";
  try {
    groupId = String((await req.json()).groupId ?? "");
  } catch {
    return reply({ error: "bad request" }, 400);
  }
  if (!UUID.test(groupId)) return reply({ error: "bad group" }, 400);

  const { data: member } = await supabase.from("group_members").select("group_id")
    .eq("group_id", groupId).eq("user_id", user.id).maybeSingle();
  if (!member) return reply({ error: "not a member" }, 403);

  const { data: profile } = await supabase.from("profiles").select("display_name").eq("id", user.id).maybeSingle();

  const token = new AccessToken(key, secret, {
    identity: user.id,
    name: profile?.display_name ?? "Motard",
    ttl: "6h",
  });
  token.addGrant({
    room: `moto-road-${groupId}`,
    roomJoin: true,
    canPublish: true,
    canSubscribe: true,
    canPublishData: false,
  });
  return reply({ token: await token.toJwt(), url });
});
