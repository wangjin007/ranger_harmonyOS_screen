export class PairTarget {
  hosts: string = '';
  port: number = 27183;
  pin: number = 0;
}

export function parsePairPayload(raw: string): PairTarget | undefined {
  const text = raw.trim();
  if (!text.startsWith('ohscreen://')) {
    return undefined;
  }
  const rest = text.substring('ohscreen://'.length);
  const q = rest.indexOf('?');
  const hostPort = q >= 0 ? rest.substring(0, q) : rest;
  const query = q >= 0 ? rest.substring(q + 1) : '';
  const colon = hostPort.lastIndexOf(':');
  if (colon < 0) {
    return undefined;
  }
  const host = hostPort.substring(0, colon);
  const port = Number.parseInt(hostPort.substring(colon + 1), 10);
  if (host.length === 0 || Number.isNaN(port) || port <= 0) {
    return undefined;
  }
  const params: Record<string, string> = {};
  const parts = query.split('&');
  for (let i = 0; i < parts.length; i++) {
    const kv = parts[i];
    const eq = kv.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    params[kv.substring(0, eq)] = decodeURIComponent(kv.substring(eq + 1));
  }
  const pin = Number.parseInt(params['pin'] ?? '0', 10);
  if (Number.isNaN(pin) || pin < 0) {
    return undefined;
  }
  const alts = params['alt'] ?? '';
  const hosts = alts.length > 0 ? `${host},${alts}` : host;
  const target = new PairTarget();
  target.hosts = hosts;
  target.port = port;
  target.pin = pin;
  return target;
}
