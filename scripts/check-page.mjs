// Syntax-checks the script the page ships.
//
// The page is a template literal that builds another program, so an unescaped backtick or apostrophe
// in the source is invisible to `node --check` on the module and only shows up as a page that does
// nothing. That has happened twice; this turns it into a failed build instead.
import { render } from '../link-service/page.mjs';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';

const html = render('syntax-check');
const script = html.slice(html.lastIndexOf('<script>') + 8, html.lastIndexOf('</script>'));
fs.writeFileSync('/tmp/private-trade-page.js', script);
try {
  execFileSync('node', ['--check', '/tmp/private-trade-page.js'], { stdio: 'pipe' });
} catch (err) {
  console.error('the page ships a script that does not parse:\n' + String(err.stderr).split('\n').slice(0, 12).join('\n'));
  process.exit(1);
}
console.log('page script parses (' + script.split('\n').length + ' lines)');
