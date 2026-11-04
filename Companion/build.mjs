import { build } from 'esbuild';
import { mkdir, copyFile, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const source = path.dirname(fileURLToPath(import.meta.url));
const out = process.argv[2];
if (!out) throw new Error('Output directory required');
await mkdir(out, { recursive: true });
const result = await build({ entryPoints: [path.join(source, 'main.mjs')], outfile: path.join(out, 'main.mjs'), bundle: true, metafile: true,
  platform: 'node', format: 'esm', target: 'node24', minify: false, external: ['./prompt.mjs'],
  banner: { js: "import { createRequire as __createRequire } from 'node:module'; const require = __createRequire(import.meta.url);" },
  legalComments: 'eof', logLevel: 'warning' });
await copyFile(path.join(source, 'mcp.mjs'), path.join(out, 'mcp.mjs'));
await copyFile(path.join(source, 'prompt.mjs'), path.join(out, 'prompt.mjs'));
const packageRoots = new Set();
for (const input of Object.keys(result.metafile.inputs)) {
  const marker = input.lastIndexOf('node_modules/'); if (marker < 0) continue;
  const remainder = input.slice(marker + 13).split('/');
  packageRoots.add(path.resolve(input.slice(0, marker + 13), ...remainder.slice(0, remainder[0].startsWith('@') ? 2 : 1)));
}
let notices = '# Bundled Companion dependencies\n\nOnly JavaScript client/read-only history functions are bundled. No Claude executable or model data is included.\n';
for (const root of [...packageRoots].sort()) {
  const info = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
  notices += `\n## ${info.name} ${info.version}\n\nLicense: ${info.license ?? 'See upstream package'}\n\n`;
  const files = (await readdir(root)).filter(name => /^(license|copying|notice)(\.|$)/i.test(name));
  for (const name of files) notices += (await readFile(path.join(root, name), 'utf8')) + '\n';
  if (!files.length) notices += `Upstream: ${typeof info.repository === 'string' ? info.repository : info.repository?.url ?? info.homepage ?? ''}\n`;
  if (info.name.startsWith('@opencode/')) notices += await readFile(path.join(source, 'licenses/OpenCode-MIT.txt'), 'utf8');
  if (info.name === '@anthropic-ai/claude-agent-sdk') notices += '\nClaude Agent SDK usage is subject to Anthropic terms: https://www.anthropic.com/legal/commercial-terms\n';
}
await writeFile(path.join(out, 'THIRD_PARTY_NOTICES.md'), notices);
