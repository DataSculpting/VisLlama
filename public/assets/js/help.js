// VisLlama: help. Loaded in the order declared in templates/partials/scripts.html.

// Human-readable field guidance, attached to the existing labels. These
// explanations do not decide build support; live --help supplies that evidence.

const HELP_TEXT={
 build:'Select which configured llama.cpp build launches llama-server. Build aliases and folders are managed in Installation and library configuration.',
 supplier:'First folder beneath the GGUF model root. Used only to organize the model picker.',
 variant:'Model-variant folder beneath the supplier. Used only to organize the model picker.',
 model:'The GGUF file passed to llama-server with -m/--model.',
 chatTemplateFile:'Optional server-side Jinja chat template passed with --chat-template-file. Leave blank to use the template embedded in the model or selected by llama.cpp.',
 gpuLayers:'How many model layers llama.cpp offloads to GPU. More GPU layers generally improve speed but consume more VRAM. Use the build-supported syntax shown by --help.',
 ctx:'Maximum context window allocated for each sequence. Larger values increase KV-cache memory use substantially.',
 contextShift:'Controls what llama.cpp does when generation reaches the available context limit. Shift discards older context and continues; Stop disables context shifting so generation terminates when the context is full. This is a server default and client request limits can still end generation earlier.',
 contextKeep:'Number of tokens from the initial prompt retained when context shifting discards older tokens. Zero keeps no extra initial prompt tokens; -1 retains the entire initial prompt. Only matters when context shifting occurs.',
 ropeScaling:'Selects the RoPE context-scaling method. Leave blank to use the scaling encoded by the model. Forcing a different method can extend or alter context behavior and should be tuned with model-specific knowledge.',
 ropeFreqBase:'Overrides the model RoPE base frequency used by NTK-aware scaling. Leave blank to use the value stored in the model unless you are deliberately tuning long-context behavior.',
 kvUnified:'Controls whether server slots share one unified KV buffer. Off requests separate per-slot KV buffers, which provides stronger slot isolation at the cost of less flexible shared-pool memory use.',
 kvUnifiedPerSlot:'Sets a hard context limit per parallel slot. When --ctx-size is otherwise automatic, current llama.cpp can size the total KV pool as parallel-slots multiplied by this value. This cap is useful even when unified KV is disabled in current server code.',
 batch:'Logical prompt-processing batch size. Larger batches can improve prompt ingestion throughput but require more memory.',
 ubatch:'Physical micro-batch size used during evaluation. Lower this when large batches cause VRAM/RAM pressure.',
 cacheK:'Data type/quantization for the K portion of the KV cache. Lower-bit types reduce memory use, potentially with a quality/performance tradeoff.',
 cacheV:'Data type/quantization for the V portion of the KV cache. Lower-bit types reduce memory use, potentially with a quality/performance tradeoff.',
 tensorSplit:'Relative distribution of tensors across multiple GPUs. Example 24,24 gives two GPUs equal weight.',
 mainGpu:'Primary GPU index used for operations that are not split across devices.',
 splitMode:'Controls how a model is divided across multiple GPUs. Layer split assigns layers; row/tensor modes split tensors according to llama.cpp support.',
 loadMode:'Controls how model data is loaded/mapped/locked. mmap generally reduces startup copying; mlock tries to keep pages resident; DIO and newer modes depend on build/platform support.',
 lazyMode:'Controls lazy tensor loading where supported, deferring some materialization until tensors are needed.',
 device:'Select the exact compute-device identifiers reported by the selected llama-server --list-devices command. Do not infer these numbers from nvidia-smi; llama.cpp device numbering can differ. Checked devices are passed to --device as a comma-separated list.',
 flash:'Enables flash attention where supported. It can improve attention speed and memory behavior, especially at longer contexts.',
 fit:'Controls llama.cpp automatic VRAM fitting. Model/build default emits no flag; Enabled forces --fit; Disabled forces --no-fit so your manual memory and GPU placement choices are not automatically adjusted.',
 fitTarget:'Sets the amount of free VRAM, in MiB, that automatic fitting should try to leave available. A single value applies to all devices; comma-separated values can set per-device targets.',
 fitCtx:'Sets the minimum context size automatic fitting may reduce to. Leave blank to use the selected llama.cpp build default.',
 cpuMoe:'Keeps Mixture-of-Experts expert weights on CPU to reduce VRAM use, trading GPU memory for CPU/RAM traffic.',
 noKvOffload:'Keeps the KV cache off the GPU. This saves VRAM but can reduce generation performance.',
 swaFull:'Uses a full-size cache for sliding-window attention models where supported. This can increase memory use.',
 noWarmup:'Skips llama.cpp warmup passes. Startup may be quicker, but first inference can expose allocation or kernel issues instead.',
 threads:'CPU worker threads used during token generation. Auto/default is usually sensible unless tuning CPU affinity or contention.',
 threadsBatch:'CPU worker threads used for prompt/batch processing. Can be tuned separately from generation threads.',
 parallel:'Number of concurrent server sequence slots. More slots allow more simultaneous requests but divide context/memory resources.',
 host:'Network interface llama-server listens on. 127.0.0.1 is local-only; use a LAN address or 0.0.0.0 only when you intentionally want remote access.',
 port:'TCP port for llama-server HTTP/OpenAI-compatible endpoints.',
 threadsHttp:'Threads dedicated to HTTP request handling, separate from model compute threads.',
 reasoning:'Controls whether the chat template enables model reasoning/thinking. Auto lets llama.cpp infer behavior from the model chat template; on/off forces the preference when supported.',
 reasoningEffort:'Passes an explicit reasoning effort level to templates that support minimal, low, medium, high, xhigh, or max. Blank leaves the decision to the model/template and can result in a very high effort on some models.',
 reasoningBudget:'Maximum reasoning/thinking token budget. -1 is unrestricted, 0 asks for an immediate end to reasoning, and positive values cap the thinking budget where supported.',
 reasoningFormat:'Controls how reasoning is returned. deepseek places thoughts in reasoning_content; none leaves thoughts unparsed in normal content. This affects API response formatting, not reasoning quality.',
 reasoningPreserve:'Controls whether supported templates preserve prior reasoning traces in conversation history. Leave at default unless the model template documents preserved thinking.',
 predict:'Server default maximum number of generated tokens. -1 means unlimited. OpenAI clients can override this with max_tokens or equivalent request fields.',
 temperature:'Controls randomness. Lower values are more deterministic; higher values broaden token selection. Model-specific recommendations often matter more than generic defaults.',
 topK:'Keeps only the K most probable candidate tokens before later samplers. 0 disables Top K.',
 topP:'Nucleus sampling threshold. Keeps the smallest token set whose cumulative probability reaches P. 1.0 disables Top P filtering.',
 minP:'Drops tokens whose probability is too small relative to the most likely token. 0 disables Min P. llama.cpp calls this Min P; there is no standard Min K sampler.',
 typicalP:'Locally typical sampling threshold. 1.0 disables it.',
 topNSigma:'Top-N-sigma filtering. -1 disables it. Useful for newer sampling recipes that prefer distribution-aware pruning.',
 repeatPenalty:'Multiplicative penalty applied to recently repeated tokens. 1.0 disables it.',
 repeatLastN:'Number of recent tokens considered for repetition penalties. 0 disables the repetition window.',
 presencePenalty:'Penalizes tokens based on whether they have appeared at all. 0 disables it.',
 frequencyPenalty:'Penalizes tokens proportionally to how often they have appeared. 0 disables it.',
 xtcProbability:'Probability that the XTC sampler is applied. 0 disables XTC.',
 xtcThreshold:'Probability threshold used by XTC when removing likely tokens. Tune together with XTC probability.',
 dynatempRange:'Enables dynamic temperature around the base temperature. 0 disables dynamic temperature.',
 dynatempExp:'Shape/exponent used by dynamic temperature when a nonzero dynamic range is enabled.',
 mirostat:'Adaptive perplexity sampler. 0 disables it; modes 1 and 2 enable Mirostat variants. Top K/Top P/Typical are generally ignored by Mirostat.',
 mirostatLR:'Mirostat adaptation learning rate (eta). Only relevant when Mirostat is enabled.',
 mirostatEnt:'Mirostat target entropy (tau). Only relevant when Mirostat is enabled.',
 seed:'Random number generator seed. -1 uses a random seed; a fixed value improves reproducibility.',
 samplers:'Explicit sampler chain/order separated by semicolons. Leave blank to use the selected llama.cpp build default.',
 dryMultiplier:'DRY repetition-control strength. 0 disables DRY.',
 dryBase:'Exponential base used by the DRY repetition penalty.',
 dryAllowedLength:'Repetition length allowed before DRY begins increasing its penalty.',
 dryPenaltyLastN:'Number of recent tokens DRY scans for repetition. 0 disables the scan.',
 ignoreEos:'Ignores the end-of-sequence token and keeps generating. Usually leave disabled for chat models.',
 specType:'Select the draft-model or MTP speculative decoding implementation. N-gram methods are configured separately below.',
 ngramType:'Select an N-gram speculative decoding method. It can be used alone or combined with the Draft / MTP type above.',
 ngramModMatch:'Lookup length for ngram-mod. Current llama.cpp default is typically 24.',
 ngramModMin:'Minimum N-gram draft length for ngram-mod. Current llama.cpp default is typically 48.',
 ngramModMax:'Maximum N-gram draft length for ngram-mod. Current llama.cpp default is typically 64.',
 ngramSimpleN:'Lookup N-gram size for ngram-simple.',
 ngramSimpleM:'Draft M-gram size for ngram-simple.',
 ngramSimpleHits:'Minimum history hits before ngram-simple is used.',
 ngramMapKN:'Lookup N-gram size for ngram-map-k.',
 ngramMapKM:'Draft M-gram size for ngram-map-k.',
 ngramMapKHits:'Minimum history hits before ngram-map-k is used.',
 ngramMapK4vN:'Lookup N-gram size for ngram-map-k4v.',
 ngramMapK4vM:'Draft M-gram size for ngram-map-k4v.',
 ngramMapK4vHits:'Minimum history hits before ngram-map-k4v is used.',
 draft:'Optional external draft GGUF. Leave this unset for integrated MTP when the target GGUF contains/advertises its MTP heads. Some architectures instead use a separate MTP/draft-head GGUF.',
 draftTokens:'Maximum speculative tokens proposed per verification step. For MTP, 2-4 is a conservative starting range; larger values only help when draft acceptance stays high.',
 draftMinTokens:'Minimum number of speculative tokens to request. Zero allows llama.cpp to fall back naturally when speculation is not useful.',
 draftPMin:'Minimum probability threshold used for speculative draft acceptance/generation. Lower values are more permissive; use the model/build defaults unless tuning acceptance.',
 draftPSplit:'Probability threshold used by speculative decoding when deciding whether to split/continue a draft path. Usually best left at the llama.cpp default initially.',
 draftNgl:'Maximum number of draft/MTP context layers to offload to GPU. Accepts the syntax supported by this build, commonly auto, all, or an integer.',
 draftDevice:'Devices used by the speculative draft/MTP context. Use llama.cpp device IDs (CUDA0, CUDA1, etc.), not nvidia-smi numbering assumptions.',
 draftTypeK:'KV-cache K type for the speculative draft/MTP context. This is separate from the target model KV-cache type.',
 draftTypeV:'KV-cache V type for the speculative draft/MTP context. This is separate from the target model KV-cache type.',
 extra:'Raw llama-server arguments, one argv item per line. Use this for new or unusual options that are not represented by the friendly controls.'
};

// Attach tooltip/help markers to friendly controls.
function decorateHelp(){for(const [id,tip] of Object.entries(HELP_TEXT)){const e=$(id);if(!e)continue;let target=e.closest('.field')?.querySelector('label');if(!target&&e.closest('.check'))target=e.closest('.check');if(!target||target.querySelector('.info'))continue;const i=document.createElement('span');i.className='info';i.tabIndex=0;i.textContent='i';i.dataset.tip=tip;i.setAttribute('aria-label','Information: '+tip);target.appendChild(i)}}

// Mount help text on document.body, outside scrolling and clipped editor panels.
function initHelpTooltips(){
 const popup=document.createElement('div');popup.className='help-popup hidden';popup.id='helpPopup';popup.setAttribute('role','tooltip');document.body.appendChild(popup);
 let anchor=null;
 function hide(){if(anchor)anchor.removeAttribute('aria-describedby');anchor=null;popup.classList.add('hidden')}
 function position(){if(!anchor||!anchor.isConnected){hide();return}const rect=anchor.getBoundingClientRect(),vw=document.documentElement.clientWidth,vh=document.documentElement.clientHeight;const width=popup.offsetWidth,height=popup.offsetHeight;const right=rect.right+10;const left=right+width<=vw-12?right:(rect.left-width-10>=12?rect.left-width-10:Math.max(12,vw-width-12));const below=rect.bottom+10;const top=below+height<=vh-12?below:(rect.top-height-10>=12?rect.top-height-10:Math.max(12,vh-height-12));popup.style.left=Math.round(left)+'px';popup.style.top=Math.round(top)+'px'}
 function show(el){if(!el?.dataset.tip)return;if(anchor!==el){hide();anchor=el;popup.textContent=el.dataset.tip;el.setAttribute('aria-describedby',popup.id);popup.classList.remove('hidden')}position()}
 document.addEventListener('pointerover',e=>{const el=e.target.closest?.('.info[data-tip]');if(el)show(el)});
 document.addEventListener('pointerout',e=>{if(anchor&&e.target===anchor&&!anchor.contains(e.relatedTarget)&&document.activeElement!==anchor)hide()});
 document.addEventListener('focusin',e=>{const el=e.target.closest?.('.info[data-tip]');if(el)show(el)});
 document.addEventListener('focusout',e=>{if(e.target===anchor)hide()});
 document.addEventListener('scroll',()=>{if(anchor)position()},true);
 window.addEventListener('resize',()=>{if(anchor)position()});
 document.addEventListener('keydown',e=>{if(e.key==='Escape')hide()});
}
