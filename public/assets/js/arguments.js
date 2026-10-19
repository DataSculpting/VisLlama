// Extra arguments are one option per line, optionally followed by its value.
// Preserve the older flag/newline/value format and literal Windows backslashes.
// This is deliberately not a shell: no expansion, escaping of paths or execution.
function parseExtraArguments(text){
 const tokens=[];let waiting=false;
 const lines=String(text||'').split(/\r?\n/);
 const failure=line=>({tokens:[],error:`Extra arguments, line ${line}: use --option value (one option per line), with matching quotes around a quoted value.`});
 const valueOf=value=>{
  const quote=value[0];
  if(quote!=='"'&&quote!=="'")return value;
  if(value.length<2||value.at(-1)!==quote)return null;
  return value.slice(1,-1).replace(quote==='"'?/\\"/g:/\\'/g,quote);
 };
 for(let i=0;i<lines.length;i++){
  const line=lines[i].trim();if(!line)continue;
  if(line.startsWith('--')){
   const match=line.match(/^(--[A-Za-z_][A-Za-z0-9_.-]*)(?:[ \t]+(.+)|=(.*))?$/);
   if(!match)return failure(i+1);
   tokens.push(match[1]);waiting=true;
   const raw=match[2]??match[3];
   if(raw!==undefined){
    // Multiple options on one line are ambiguous with legacy unquoted values.
    if(!/^["']/.test(raw)&&/(?:^|\s)--[A-Za-z_]/.test(raw))return failure(i+1);
    const value=valueOf(raw);if(value===null||/[\x00-\x08\x0b\x0c\x0e-\x1f]/.test(value))return failure(i+1);
    tokens.push(value);waiting=false;
   }
  }else{
   if(!waiting)return failure(i+1);
   // Existing standalone values remain a single token, even with spaces.
   const value=valueOf(line);if(value===null||/[\x00-\x08\x0b\x0c\x0e-\x1f]/.test(value))return failure(i+1);
   tokens.push(value);waiting=false;
  }
 }
 return {tokens,error:''};
}
