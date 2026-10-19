// GPL-3.0-only. Browser persistence is behind a replaceable interface; quota failures surface.
(()=>{
 const C=globalThis.VisLlamaChat,PREFIX='visllama.chat.v1.';
 C.BrowserStore=class{
  constructor(storage=localStorage){this.storage=storage}
  async list(){const items=[];for(let i=0;i<this.storage.length;i++){const key=this.storage.key(i);if(!key?.startsWith(PREFIX))continue;const c=await this.load(key.slice(PREFIX.length));items.push({id:c.id,title:c.title,updatedAt:c.updatedAt})}return items.sort((a,b)=>b.updatedAt-a.updatedAt)}
  async load(id){const text=this.storage.getItem(PREFIX+id);if(text===null)return null;let c;try{c=JSON.parse(text)}catch{throw new Error('A saved conversation is damaged. Its stored data was retained.')}if(!C.validate(c))throw new Error('A saved conversation uses an unsupported format. Its stored data was retained.');for(const m of c.messages)if(['pending','streaming'].includes(m.status))m.status='aborted';return c}
  async save(c){if(!C.validate(c))throw new Error('Conversation could not be saved.');this.storage.setItem(PREFIX+c.id,JSON.stringify(c))}
  async delete(id){this.storage.removeItem(PREFIX+id)}
 };
})();
