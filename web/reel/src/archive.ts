// Arkivsidan (/a#<token>): spelar upp färdiga renderingar och delar dem.
// Web Share med fil när `navigator.canShare({files})` stöds (iOS Safari 15+),
// annars vanlig nedladdning. Token ligger i fragmentet och går bara som header.

import { ShareClient, ShareError, STATUS_TEXT, tokenFromHash } from "./shareApi.ts";
import type { RenderItem, ShareView } from "./shareApi.ts";

const $ = <T extends HTMLElement>(id: string): T => document.getElementById(id) as T;

function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls?: string, text?: string): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

function message(text: string, err = false): void {
  const m = $("msg");
  m.textContent = text;
  m.className = "msg" + (err ? " err" : "");
  m.hidden = text === "";
}

const mb = (n: number): string => `${(n / 1048576).toFixed(1).replace(".", ",")} MB`;
const sec = (n: number): string => `${n.toFixed(1).replace(".", ",")} s`;

/** Kan webbläsaren dela en fil av den här typen? */
export function canShareFile(file: File): boolean {
  return typeof navigator !== "undefined" && typeof navigator.canShare === "function" && navigator.canShare({ files: [file] });
}

function download(blob: Blob, name: string): void {
  const a = el("a");
  a.href = URL.createObjectURL(blob);
  a.download = name;
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
}

function renderItem(r: RenderItem, view: ShareView, first: boolean): HTMLElement {
  const box = el("section", "card render");
  const title = r.current ? "Senaste filmen" : "Tidigare version";
  box.append(el("h2", undefined, `${title}${r.outputId ? ` (${r.outputId})` : ""}`));

  const video = el("video");
  video.controls = true;
  video.playsInline = true;
  video.preload = first ? "metadata" : "none";
  video.src = r.url;
  box.append(video);

  const parts = [mb(r.bytes)];
  if (r.duration) parts.unshift(sec(r.duration));
  if (r.width && r.height) parts.unshift(`${r.width}×${r.height}`);
  box.append(el("p", "meta", `${parts.join(" · ")} · ${view.object.address}`));

  const row = el("div", "row");
  const shareBtn = el("button", "btn primary", "Dela");
  const dl = el("a", "btn", "Ladda ner");
  dl.href = r.url;
  dl.download = "Objektfilm.mp4";
  let file: File | null = null;
  let loading = false;

  async function ensureFile(): Promise<File> {
    if (file) return file;
    const resp = await fetch(r.url, { referrerPolicy: "no-referrer" });
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    file = new File([await resp.blob()], "Objektfilm.mp4", { type: "video/mp4" });
    return file;
  }

  shareBtn.addEventListener("click", async () => {
    if (loading) return;
    loading = true;
    shareBtn.textContent = "Förbereder…";
    try {
      const f = await ensureFile();
      if (canShareFile(f)) {
        try {
          await navigator.share({ files: [f], title: "Objektfilm" });
          shareBtn.textContent = "Dela";
        } catch (e) {
          // Avbruten delning är inget fel. Har webbläsaren hunnit tappa användargesten ber vi om ett tryck till.
          if ((e as DOMException).name === "NotAllowedError") shareBtn.textContent = "Tryck igen för att dela";
          else shareBtn.textContent = "Dela";
        }
      } else {
        download(f, "Objektfilm.mp4");
        message("Din webbläsare kan inte dela filer direkt, så filmen laddades ner i stället.");
        shareBtn.textContent = "Dela";
      }
    } catch {
      message("Kunde inte hämta filmen. Försök igen.", true);
      shareBtn.textContent = "Dela";
    } finally {
      loading = false;
    }
  });
  row.append(shareBtn, dl);
  box.append(row);
  return box;
}

function show(view: ShareView): void {
  $("badge").hidden = false;
  $("badge").textContent = `${view.object.address} · ${STATUS_TEXT[view.object.status]}`;
  const list = $("list");
  list.replaceChildren();
  // Senaste först; "current" överst.
  const sorted = [...view.renders].sort((a, b) => Number(b.current) - Number(a.current) || b.createdAt.localeCompare(a.createdAt));
  sorted.forEach((r, i) => list.append(renderItem(r, view, i === 0)));
  $("empty").hidden = sorted.length > 0;
}

async function main(): Promise<void> {
  const token = tokenFromHash(location.hash);
  if (!token) { message("Länken är ofullständig. Be fotografen skicka den igen.", true); return; }
  const client = new ShareClient(token);
  let shown = "";
  const load = async (): Promise<boolean> => {
    try {
      const view = await client.get();
      const sig = view.renders.map((r) => r.renderId).join(",") + view.object.status;
      if (sig !== shown) { shown = sig; show(view); }
      return view.object.status === "rendered";
    } catch (e) {
      message(e instanceof ShareError ? e.message : "Något gick fel.", true);
      return true; // sluta försöka vid fel som länk utgången
    }
  };
  const done = await load();
  if (!done) {
    // Väntar på rendering: uppdatera tills filmen finns (video-URL:erna är signerade i en timme).
    const t = window.setInterval(async () => { if (await load()) clearInterval(t); }, 8000);
  }
}

window.addEventListener("hashchange", () => location.reload());
void main();
