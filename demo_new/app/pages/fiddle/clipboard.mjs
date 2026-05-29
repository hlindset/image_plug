export async function copy(text) {
  try { await navigator.clipboard.writeText(text); return { ok: true }; }
  catch (e) { return { ok: false, message: String((e && e.message) || e) }; }
}
