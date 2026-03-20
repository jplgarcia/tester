// Binary search for the last processed input index
const APP = '0x618f4c02eeaca01fb7c18ff8874c77fdca7bda9a';
const RPC = 'http://127.0.0.1:6751/rpc';

async function getInputStatus(idx) {
  const r = await fetch(RPC, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', method: 'cartesi_getInput', params: { application: APP, input_index: '0x' + idx.toString(16) }, id: 1 }),
  });
  const j = await r.json();
  return j?.result?.status ?? null;
}

// Scan from 0 to 70 to find last processed and gap
for (let i = 0; i <= 80; i++) {
  const s = await getInputStatus(i);
  if (s !== null) {
    console.log(`${i} (0x${i.toString(16)}): ${s}`);
  } else {
    process.stdout.write(`${i}:none `);
  }
}
console.log('\ndone');
