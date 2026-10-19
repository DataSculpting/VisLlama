// GPL-3.0-only. Incremental UTF-8/SSE framing; JSON interpretation belongs to the provider.
(()=>{
 const C=globalThis.VisLlamaChat;
 C.SSEParser=class{
  constructor(accept){this.accept=accept;this.decoder=new TextDecoder('utf-8',{fatal:true});this.buffer='';this.lines=[];this.size=0;this.done=false;this.bom=true}
  line(line){if(this.bom){line=line.replace(/^\uFEFF/,'');this.bom=false}if(line===''){const data=[],names=[];for(const l of this.lines){if(l.startsWith('data:'))data.push(l.slice(5).replace(/^ /,''));if(l.startsWith('event:'))names.push(l.slice(6).trim())}this.lines=[];this.size=0;if(data.length){const value=data.join('\n');if(value==='[DONE]'){this.done=true;return}this.accept(value,names.at(-1)||'message')}return}this.lines.push(line);this.size+=line.length;if(this.size>8*1024*1024)throw new Error('The streaming event exceeded its size limit.')}
  push(bytes,final=false){if(this.done)return;this.buffer+=this.decoder.decode(bytes||new Uint8Array(),{stream:!final});if(this.buffer.length>8*1024*1024)throw new Error('The streaming event exceeded its size limit.');while(!this.done){const match=/\r\n|\n|\r/.exec(this.buffer);if(!match)break;if(match[0]==='\r'&&match.index===this.buffer.length-1&&!final)break;const line=this.buffer.slice(0,match.index);this.buffer=this.buffer.slice(match.index+match[0].length);this.line(line)}if(final&&!this.done&&(this.buffer||this.lines.length))throw new Error('The stream ended inside an incomplete event.')}
 };
})();
