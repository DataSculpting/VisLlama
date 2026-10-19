// GPL-3.0-only. Established parsers render untrusted output; HTML is sanitized before mounting.
(()=>{
 const C=globalThis.VisLlamaChat;
 // Protect TeX from Markdown's escape/emphasis lexer, outside fenced/inline code.
 // The extension emits escaped text only; KaTeX subsequently renders that text.
 const escape=text=>text.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const markdown=new marked.Marked({gfm:true,breaks:false,extensions:[{name:'chatMath',level:'inline',start:src=>src.search(/\$|\\[([]/),tokenizer(src){const match=/^(\$\$[\s\S]+?\$\$|\\\[[\s\S]+?\\\]|\\\([\s\S]+?\\\)|\$[^$\n]+?\$)/.exec(src);if(match)return {type:'chatMath',raw:match[0],text:match[0]}},renderer:token=>escape(token.text)}]});
 C.renderMarkdown=(root,text)=>{
  root.innerHTML=DOMPurify.sanitize(markdown.parse(text),{USE_PROFILES:{html:true},FORBID_TAGS:['img','style','form','input'],FORBID_ATTR:['style'],ALLOW_DATA_ATTR:false});
  root.querySelectorAll('a').forEach(a=>{a.target='_blank';a.rel='noopener noreferrer'});
  for(const code of root.querySelectorAll('pre>code')){
   const raw=code.textContent,language=[...code.classList].find(c=>c.startsWith('language-'))?.slice(9)||'text';
   if(hljs.getLanguage(language)&&raw.length<100000)try{code.innerHTML=hljs.highlight(raw,{language,ignoreIllegals:true}).value}catch{}
   const bar=document.createElement('div');bar.className='chat-code-bar';const label=document.createElement('span');label.textContent=language;const copy=document.createElement('button');copy.type='button';copy.textContent='Copy code';copy.onclick=async()=>{try{await navigator.clipboard.writeText(raw);copy.textContent='Copied'}catch{copy.textContent='Copy failed'}};bar.append(label,copy);code.parentElement.before(bar);
  }
  // Macros are fresh for each render; untrusted TeX cannot load external content.
  renderMathInElement(root,{delimiters:[{left:'$$',right:'$$',display:true},{left:'\\[',right:'\\]',display:true},{left:'\\(',right:'\\)',display:false},{left:'$',right:'$',display:false}],throwOnError:false,trust:false,strict:'ignore',maxExpand:1000,macros:{},ignoredTags:['script','noscript','style','textarea','pre','code']});
 };
 C.metricText=m=>{const out=[];if(Number.isFinite(m.completionTokens))out.push(m.completionTokens+' tokens');if(Number.isFinite(m.generationTokensPerSecond))out.push(m.generationTokensPerSecond.toFixed(1)+' tok/s'+(m.source?.generationSpeed==='client'?' (client)':''));if(Number.isFinite(m.ttftMs))out.push('TTFT '+Math.round(m.ttftMs)+' ms');if(Number.isFinite(m.prefillTokensPerSecond))out.push('Prefill '+m.prefillTokensPerSecond.toFixed(1)+' tok/s');if(Number.isFinite(m.contextPercent))out.push(m.tokensInContext+' / '+m.contextSize+' tokens · '+m.contextPercent.toFixed(1)+'% context');return out.join(' · ')};
})();
