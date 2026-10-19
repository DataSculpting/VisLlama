const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),{JSDOM}=require('jsdom');
const dom=new JSDOM('<!doctype html><div id="root"></div>',{runScripts:'outside-only',url:'http://localhost/'}),w=dom.window,root=w.document.getElementById('root');let copied;
w.navigator.clipboard={writeText:async text=>{copied=text}};
const base=path.join(__dirname,'../public/assets/js/chat');
for(const name of ['conversation','vendor/marked','vendor/purify','vendor/highlight','vendor/katex','vendor/math','rendering'])w.eval(fs.readFileSync(path.join(base,name+'.js'),'utf8'));
(async()=>{
 const markdown='# Heading\n\n- One\n  - Nested\n\n|a|b|\n|-|-|\n|1|2|\n\n```js\nconst x = "<raw>";\n```\n\n$E=mc^2$\n\n$$\\frac{1}{2}$$\n\n<script>window.pwned=true</script><img src="https://private/" onerror="window.pwned=true"><a href="javascript:alert(1)">bad</a>';
 w.VisLlamaChat.renderMarkdown(root,markdown);assert(root.querySelector('h1'));assert(root.querySelector('ul ul'));assert(root.querySelector('table'));assert(root.querySelector('.hljs-keyword'));assert.equal(root.querySelectorAll('.katex').length,2);assert(!root.querySelector('script,img,[onerror],a[href^="javascript:"]'));assert(!w.pwned);
 await root.querySelector('.chat-code-bar button').onclick();assert.equal(copied,'const x = "<raw>";\n');
 w.VisLlamaChat.renderMarkdown(root,'```python\nprint("partial');assert(root.querySelector('pre code'));assert.match(root.textContent,/partial/);
 w.VisLlamaChat.renderMarkdown(root,'\\(x^2\\) and \\[y^2\\]');assert.equal(root.querySelectorAll('.katex').length,2,'backslash math delimiters survive Markdown');
 dom.window.close();console.log('Chat rendering passed: GFM, highlight, raw code copy, math, partial fences and sanitized hostile HTML');
})().catch(e=>{dom.window.close();console.error(e);process.exitCode=1});
