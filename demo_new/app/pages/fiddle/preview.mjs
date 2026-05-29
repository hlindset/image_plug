let currentController = null;
let currentObjectUrl = null;

export async function load(url) {
  if (currentController) currentController.abort();
  const controller = new AbortController();
  currentController = controller;
  const timeout = setTimeout(() => controller.abort(), 15000);

  try {
    const response = await fetch(url, { signal: controller.signal, headers: { Accept: "image/avif,image/webp,image/*,*/*;q=0.8" } });
    if (!response.ok) {
      const body = await response.text().catch(() => "");
      return { ok: false, kind: "http", status: response.status, statusText: response.statusText, body };
    }
    const blob = await response.blob();
    const objectUrl = URL.createObjectURL(blob);
    const size = await naturalSize(objectUrl);
    if (currentObjectUrl) URL.revokeObjectURL(currentObjectUrl);
    currentObjectUrl = objectUrl;
    return {
      ok: true,
      objectUrl,
      width: size.width,
      height: size.height,
      bytes: blob.size,
      contentType: blob.type || response.headers.get("content-type") || "",
    };
  } catch (error) {
    if (error && error.name === "AbortError") return { ok: false, kind: "abort" };
    return { ok: false, kind: "error", message: String((error && error.message) || error) };
  } finally {
    clearTimeout(timeout);
    if (currentController === controller) currentController = null;
  }
}

function naturalSize(objectUrl) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve({ width: img.naturalWidth, height: img.naturalHeight });
    img.onerror = () => reject(new Error("decode failed"));
    img.src = objectUrl;
  });
}

export function teardown() {
  if (currentController) currentController.abort();
  if (currentObjectUrl) { URL.revokeObjectURL(currentObjectUrl); currentObjectUrl = null; }
}
