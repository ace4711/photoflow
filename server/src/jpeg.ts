// Läser JPEG-huvudet: mått och om det finns GPS-data i EXIF. Ingen bildbehandling.

export class JpegError extends Error {}

export interface JpegInfo { width: number; height: number; hasGps: boolean }

function exifHasGps(seg: Uint8Array): boolean {
  // seg börjar efter markörens längdfält: "Exif\0\0" + TIFF
  if (seg.length < 14 || String.fromCharCode(...seg.subarray(0, 4)) !== "Exif") return false;
  const t = seg.subarray(6);
  const le = t[0] === 0x49 && t[1] === 0x49;
  if (!le && !(t[0] === 0x4d && t[1] === 0x4d)) return false;
  const dv = new DataView(t.buffer, t.byteOffset, t.byteLength);
  const u16 = (o: number) => dv.getUint16(o, le);
  const u32 = (o: number) => dv.getUint32(o, le);
  if (t.length < 8) return false;
  const ifd = u32(4);
  if (ifd + 2 > t.length) return false;
  const n = u16(ifd);
  for (let i = 0; i < n; i++) {
    const o = ifd + 2 + i * 12;
    if (o + 12 > t.length) break;
    if (u16(o) === 0x8825) return true;
  }
  return false;
}

export function inspectJpeg(buf: Uint8Array): JpegInfo {
  if (buf.length < 4 || buf[0] !== 0xff || buf[1] !== 0xd8) throw new JpegError("Filen är inte en JPEG-bild.");
  let i = 2;
  let hasGps = false;
  while (i + 4 <= buf.length) {
    if (buf[i] !== 0xff) throw new JpegError("Trasig JPEG (markör saknas).");
    let m = buf[i + 1];
    while (m === 0xff && i + 2 < buf.length) { i++; m = buf[i + 1]; }
    if (m === 0xd8 || (m >= 0xd0 && m <= 0xd7) || m === 0x01) { i += 2; continue; }
    const len = (buf[i + 2] << 8) | buf[i + 3];
    if (len < 2 || i + 2 + len > buf.length) throw new JpegError("Trasig JPEG (segmentet är avkortat).");
    const seg = buf.subarray(i + 4, i + 2 + len);
    if (m === 0xe1 && exifHasGps(seg)) hasGps = true;
    const isSof = m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc;
    if (isSof) {
      if (seg.length < 5) throw new JpegError("Trasig JPEG (SOF).");
      const height = (seg[1] << 8) | seg[2];
      const width = (seg[3] << 8) | seg[4];
      if (width < 1 || height < 1) throw new JpegError("JPEG saknar mått.");
      return { width, height, hasGps };
    }
    if (m === 0xda) break;
    i += 2 + len;
  }
  throw new JpegError("Hittade inga bildmått i JPEG-filen.");
}
