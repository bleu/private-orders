// Syntax-checks the script the page ships.
//
// The page is a template literal that builds another program, so an unescaped backtick or apostrophe
// in the source is invisible to `node --check` on the module and only shows up as a page that does
// nothing. That has happened twice; this turns it into a failed build instead.
import { render, renderCreate } from '../link-service/page.mjs';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';

// The fixtures ship two more programs the same way: a fake `forge` and a fake `cast`, both built
// inside template literals. An unescaped backtick in a comment there breaks the harness at import,
// which is later and less obviously than breaking it here.
const fixtures = await import('../docs/review/fixtures.mjs');
const pages = {
  offer: render('syntax-check', { devWallet: true }),
  create: renderCreate({ devWallet: true, defaults: { sellToken: '0x0', buyToken: '0x0' } }),
  forge: fixtures.forgeSource(),
  cast: fixtures.castSource(),
};

for (const [name, html] of Object.entries(pages)) {
  // A page's last script is its own; the development wallet shim, if present, comes first. A fixture
  // is a whole script already.
  const script = name === 'offer' || name === 'create'
    ? html.slice(html.lastIndexOf('<script>') + 8, html.lastIndexOf('</script>'))
    : html;
  const file = `/tmp/private-trade-${name}.js`;
  fs.writeFileSync(file, script);
  try {
    execFileSync('node', ['--check', file], { stdio: 'pipe' });
  } catch (err) {
    console.error(`the ${name} page ships a script that does not parse:\n` + String(err.stderr).split('\n').slice(0, 12).join('\n'));
    process.exit(1);
  }
  console.log(`${name} page script parses (${script.split('\n').length} lines)`);
}
