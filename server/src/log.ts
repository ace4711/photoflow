// JSON-loggning till stdout. Inga adresser, namn, IP-adresser, user-agent eller tokens.

export type Level = "info" | "warn" | "error";

let sink: (line: string) => void = (l) => process.stdout.write(l + "\n");
export function setLogSink(f: (line: string) => void): void { sink = f; }

export function log(level: Level, msg: string, fields: Record<string, unknown> = {}): void {
  sink(JSON.stringify({ t: new Date().toISOString(), level, msg, ...fields }));
}
