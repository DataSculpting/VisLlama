// Check the actual stylesheet cascade in both motion modes. Pixel snapshots
// alone cannot catch an animation disabled by a media query or !important.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {JSDOM}=require('jsdom');
const source = require('./support/ui.cjs').inlineHTML();
const html=source;
const dom=new JSDOM(html),document=dom.window.document;
const emblem=document.querySelector('.startup-splash-emblem');
function effectiveAnimation(reduced){
 let winner=null,order=0;
 function visit(rules){for(const rule of rules){
  if(rule.media){
   const query=rule.media.mediaText;
   const enabled=query.includes('prefers-reduced-motion')?reduced:
    [...query.matchAll(/(min|max)-(width|height):\s*(\d+)px/g)].every(([,bound,axis,n])=>bound==='max'?(axis==='width'?1200:900)<=+n:(axis==='width'?1200:900)>=+n);
   if(enabled)visit(rule.cssRules);continue;
  }
  if(!rule.selectorText)continue;
  for(const selector of rule.selectorText.split(',')){
   if(!selector.trim().endsWith('::after'))continue;
   const base=selector.trim().slice(0,-7);
   if(!emblem.matches(base))continue;
   const animation=rule.style.getPropertyValue('animation');if(!animation)continue;
   const priority=rule.style.getPropertyPriority('animation')==='important'?1:0;
   // The matching source selectors use IDs, classes, types or universals.
   const specificity=(base.match(/#[\w-]+/g)||[]).length*10000+(base.match(/\.[\w-]+/g)||[]).length*100+(base.match(/(^|\s)[a-z][\w-]*/g)||[]).length;
   const candidate={animation,priority,specificity,order:order++};
   if(!winner||candidate.priority>winner.priority||candidate.priority===winner.priority&&(candidate.specificity>winner.specificity||candidate.specificity===winner.specificity&&candidate.order>winner.order))winner=candidate;
  }
 }}
 for(const sheet of document.styleSheets)visit(sheet.cssRules);
 return winner?.animation||'none';
}
assert.match(effectiveAnimation(false),/^splashSweep 1\.7s linear infinite$/,'Normal mode keeps the original traveling highlight');
assert.match(effectiveAnimation(true),/^splashSweep 3\.6s linear 1 forwards$/,'Reduced motion retains the original slower traveling highlight');
assert.match(source,/@keyframes splashSweep\{from\{background-position:100% 50%\}to\{background-position:0% 50%\}\}/,'Sweep changes position across the logo');
// Reproduce the regression introduced by the redesign: an important universal
// stop must beat the reduced-motion splash rule, and this test must detect it.
const regression=document.createElement('style');
regression.textContent='@media(prefers-reduced-motion:reduce){*::after{animation:none!important}}';
document.head.appendChild(regression);
assert.equal(effectiveAnimation(true),'none','Cascade check detects the former blanket animation stop');
regression.remove();
assert.match(effectiveAnimation(true),/^splashSweep/);
dom.window.close();
console.log('Splash motion cascade passed in normal and reduced-motion modes (not a browser animation test)');
