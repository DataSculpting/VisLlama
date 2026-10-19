# Strata engine definition

The bundled definition is revision **1.3.2**, schema **1.1**. One definition serves
prepared installations sharing its server/configuration contract. Register each
installation as a named build with its own stable ID.

Choose the prepared Python interpreter for `serve/server.py` and the separate
native inference executable for model execution and option discovery. Import a
working JSON file or configure prepared model/tokenizer paths in the shared
model editor. Library folders have Add/Browse/Remove and Check / detect controls.
VisLlama does not install Strata, prepare models or create their data packs.

Named controls cover pipeline/layer sharing, request slots, context/cache,
expert settings, speculation/MTP and memory/runtime paths. Reviewed base controls
are editable with advisory support guidance; discovered additions require current
installed-build evidence. GPU values remain engine-native and do not enable
VisLlama Calculated placement. Busy-GPU automatic fitting is not guaranteed.

See [Engine extensions](../../docs/ENGINES.md) for the schema, reviewed source
references, local-definition updates, additive discovery and lifecycle limits.
Retain `presets/engines/` on upgrade; bundled defaults can be replaced, while
retained custom definitions remain under user control.
