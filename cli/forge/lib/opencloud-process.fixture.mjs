// Owned local pipe barrier only; never performs network IO.
process.stderr.write('fixture diagnostic\n');
for await (const _chunk of process.stdin) { /* Drain to EOF. */ }
process.stdout.write('READY\n');
if (process.argv[2] === 'exit') {
  process.stdout.write('DONE\n');
} else {
  // Remain alive on an owned IPC-free server handle until the parent kills us.
  const { createServer } = await import('node:net');
  const server = createServer();
  server.listen(0, '127.0.0.1');
}
