// Ownership is registered before an operation can allocate anything. Adapters
// must reconcile an attempted allocation even when its response was lost.
export class StudioLifecycle {
  constructor({ timeoutMs = 10000, schedule = setTimeout, unschedule = clearTimeout } = {}) {
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error('INVALID_LIFECYCLE_TIMEOUT');
    this.timeoutMs = timeoutMs;
    this.schedule = schedule;
    this.unschedule = unschedule;
    this.resources = [];
    this.disposers = new Map();
    this.failure = null;
    this.closing = false;
  }

  attempt(kind, id, dispose) {
    if (this.closing) throw new Error('LIFECYCLE_CLOSED');
    if (!kind || !id || typeof dispose !== 'function' || this.resources.some(row => row.id === id)) throw new Error('INVALID_OWNED_RESOURCE');
    const row = { kind, id, state: 'attempted', acquired: false, cleanup: 'pending' };
    this.resources.push(row);
    this.disposers.set(row, dispose);
    return row;
  }

  acquire(row, identity) {
    if (!this.disposers.has(row) || this.closing || row.acquired || !identity) throw new Error('INVALID_RESOURCE_ACQUISITION');
    row.identity = identity;
    row.acquired = true;
    row.state = 'acquired';
  }

  fail(phase, code) {
    this.failure ??= { phase, code };
  }

  // subscribe must synchronously return an unsubscribe function. It registers
  // the exact target event before action runs, including synchronous events.
  // Both action completion AND the required event are necessary for success.
  async observe({ phase, subscribe, action, signal, timeoutMs = this.timeoutMs }) {
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error('INVALID_LIFECYCLE_TIMEOUT');
    const controller = new AbortController();
    let timer, unsubscribe, onAbort;
    let resolveEvent, rejectEvent;
    const event = new Promise((resolve, reject) => { resolveEvent = resolve; rejectEvent = reject; });
    // An event may reject during registration, before Promise.all is attached.
    event.catch(() => {});
    const stopped = new Promise((_, reject) => {
      const stop = code => { controller.abort(); reject(new Error(code)); };
      onAbort = () => stop('CANCELLED');
      signal?.addEventListener('abort', onAbort, { once: true });
      timer = this.schedule(() => stop('OPERATION_TIMEOUT'), timeoutMs);
    });
    stopped.catch(() => {});
    try {
      if (signal?.aborted) throw new Error('CANCELLED');
      unsubscribe = subscribe(resolveEvent, rejectEvent);
      if (typeof unsubscribe !== 'function') throw new Error('SUBSCRIPTION_DISPOSER_REQUIRED');
      if (signal?.aborted) throw new Error('CANCELLED');
      const result = Promise.resolve().then(() => {
        if (controller.signal.aborted) throw new Error('CANCELLED');
        return action(controller.signal);
      });
      const [value, observed] = await Promise.race([Promise.all([result, event]), stopped]);
      return { value, observed };
    } catch (error) {
      const code = ['CANCELLED', 'OPERATION_TIMEOUT', 'SUBSCRIPTION_DISPOSER_REQUIRED'].includes(error?.message) ? error.message : 'OPERATION_FAILED';
      this.fail(phase, code);
      throw error;
    } finally {
      controller.abort();
      this.unschedule(timer);
      signal?.removeEventListener('abort', onAbort);
      try { unsubscribe?.(); }
      catch (error) { this.fail(phase, 'SUBSCRIPTION_CLEANUP_FAILED'); throw error; }
    }
  }

  close() {
    if (this.closing) return this.closed;
    this.closing = true;
    this.closed = this.disposeAll();
    return this.closed;
  }

  async disposeAll() {
    // Reverse acquisition order keeps transport alive until remote cleanup has
    // finished. A failed disposer never prevents later disposers from running.
    for (const row of [...this.resources].reverse()) {
      await this.release(row);
    }
    return this.receipt();
  }

  release(row) {
    if (!this.disposers.has(row)) return Promise.reject(new Error('FOREIGN_RESOURCE'));
    // Store outside the serialized ledger: receipts must remain plain data.
    this.releases ??= new Map();
    if (this.releases.has(row)) return this.releases.get(row);
    const pending = this.disposeOne(row);
    this.releases.set(row, pending);
    return pending;
  }

  async disposeOne(row) {
      let timer;
      const controller = new AbortController();
      try {
        const proof = await Promise.race([
          Promise.resolve().then(() => this.disposers.get(row)(row, controller.signal)),
          new Promise((_, reject) => { timer = this.schedule(() => { controller.abort(); reject(new Error('CLEANUP_TIMEOUT')); }, this.timeoutMs); }),
        ]);
        if (proof?.released !== true || !proof.evidence) throw new Error('CLEANUP_UNPROVEN');
        row.cleanup = 'released';
        row.evidence = proof.evidence;
        row.state = 'released';
      } catch {
        row.cleanup = 'unresolved';
        this.fail('cleanup', 'OWNED_RESOURCE_UNRESOLVED');
      } finally {
        controller.abort();
        this.unschedule(timer);
      }
    return { released: row.cleanup === 'released', evidence: row.evidence, resource: row.id };
  }

  receipt() {
    const resources = this.resources.map(row => ({ ...row }));
    return {
      schemaVersion: 1,
      ok: this.closing && !this.failure && resources.every(row => row.cleanup === 'released'),
      failure: this.failure && { ...this.failure },
      resources,
      residuals: resources.filter(row => row.cleanup !== 'released').map(row => row.id),
    };
  }
}
