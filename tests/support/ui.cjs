// Exercise the real Perl renderer, then inline its declared local assets for
// isolated jsdom/VM tests. The application itself serves external assets.
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const root = path.resolve(__dirname, '../..');
let rendered;
function html() {
  if (rendered === undefined) {
    rendered = execFileSync(process.env.PERL || 'perl', [
      '-I', path.join(root, 'lib'), '-MVisLlama::View',
      '-e', 'print VisLlama::View::app_html();'
    ], {encoding:'utf8', cwd:root});
  }
  return rendered;
}
function asset(url) {
  const relative = url.split('?')[0];
  if (!/^\/assets\/(css|js)\/(?:[a-z-]+\/)*[a-z-]+\.(css|js)$/.test(relative)) throw new Error('Unexpected test asset: '+url);
  return fs.readFileSync(path.join(root, 'public', relative), 'utf8');
}
function inlineHTML() {
  return html()
    .replace(/<link rel="stylesheet" href="([^"]+)">/g, (_,url)=>'<style>'+asset(url)+'</style>')
    .replace(/<script src="([^"]+)"><\/script>/g, (_,url)=>'<script>'+asset(url)+'</script>');
}
module.exports = {root, html, asset, inlineHTML};
