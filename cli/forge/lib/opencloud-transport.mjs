// One native fetch, no redirects or retries. Protocol output never contains secrets.
import { pathToFileURL } from 'node:url';

export async function requestOnce(input, { signal, fetchImpl = fetch } = {}) {
  const controller = new AbortController();
  const abort = () => controller.abort();
  signal?.addEventListener('abort', abort, { once: true });
  if (signal?.aborted) abort();
  const timer = setTimeout(abort, 30_000);
  try {
    const response = await fetchImpl(input.url, {
      method: 'POST', redirect: 'error', signal: controller.signal,
      headers: input.headers, body: input.body,
    });
    // Bound provider output and keep the deadline active through body consumption.
    const reader = response.body?.getReader();
    let size = 0;
    const chunks = [];
    if (reader) {
      try {
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          size += value.byteLength;
          if (size > 65536) {
            await reader.cancel();
            return { error: 'PUBLISH_MALFORMED_REPLY' };
          }
          chunks.push(value);
        }
      } finally { reader.releaseLock(); }
    }
    let body = '';
    if (response.ok) {
      try {
        const decoded = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (decoded && typeof decoded === 'object' && !Array.isArray(decoded)) {
          // Place version replies may include provider metadata. Reject explicit
          // error envelopes even with a version; otherwise discard extra fields.
          if (!('error' in decoded) && !('errors' in decoded) && Number.isSafeInteger(decoded.versionNumber) && decoded.versionNumber > 0)
            body = JSON.stringify({ versionNumber: decoded.versionNumber });
          else if (Object.keys(decoded).length === 0) body = '{}';
        }
      } catch { /* A success with invalid JSON is classified by the caller. */ }
    }
    return { statusCode: response.status, ok: response.ok, body };
  } catch {
    return { error: controller.signal.aborted ? 'PUBLISH_TIMEOUT_AMBIGUOUS' : 'PUBLISH_TRANSPORT_AMBIGUOUS' };
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', abort);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  // Input arrival is bounded by the owning Lune watchdog, including startup.
  let result;
  try {
    if (typeof fetch !== 'function' || typeof AbortController !== 'function') {
      process.stdout.write(JSON.stringify({ error: 'PUBLISH_TRANSPORT_UNSUPPORTED' }) + '\n');
      process.exit(0);
    }
    const chunks = [];
    for await (const chunk of process.stdin) chunks.push(chunk);
    const bytes = Buffer.concat(chunks);
    const split = bytes.indexOf(10);
    if (split < 0) throw new Error('frame');
    const input = JSON.parse(bytes.subarray(0, split).toString('utf8'));
    input.body = bytes.subarray(split + 1);
    const url = new URL(input.url);
    if (url.origin !== 'https://apis.roblox.com' || url.username || url.password ||
        !(/^\/universes\/v1\/\d+\/places\/\d+\/versions\?versionType=Published$/.test(url.pathname + url.search) ||
          /^\/cloud\/v2\/universes\/\d+\/:publishMessage$/.test(url.pathname + url.search)))
      throw new Error('target');
    result = await requestOnce(input);
  } catch { result = { error: 'PUBLISH_TRANSPORT_AMBIGUOUS' }; }
  process.stdout.write(JSON.stringify(result) + '\n');
}
