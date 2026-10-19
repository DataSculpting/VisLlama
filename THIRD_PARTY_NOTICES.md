# Bundled Chat rendering dependencies

VisLlama original code remains GPL-3.0-only. These established browser libraries
retain their upstream license terms and are loaded locally; there is no runtime
CDN/network dependency, package installation, Node service or frontend build.

| Dependency | Pinned version | Upstream | License file |
| --- | --- | --- | --- |
| Marked | 17.0.5 | https://github.com/markedjs/marked | third-party/marked-LICENSE.txt (MIT notices) |
| DOMPurify | 3.4.16 | https://github.com/cure53/DOMPurify | third-party/dompurify-LICENSE.txt (Apache-2.0 / MPL-2.0 upstream terms) |
| highlight.js CDN assets | 11.11.1 | https://github.com/highlightjs/cdn-release | third-party/highlightjs-LICENSE.txt (BSD-3-Clause) |
| KaTeX + auto-render + fonts | 0.18.7 | https://github.com/KaTeX/KaTeX | third-party/katex-LICENSE.txt (MIT) |

Upstream browser bundles were copied without a runtime transformation. Files are
named marked.js, purify.js, highlight.js, katex.js and math.js under the Chat vendor
directory. KaTeX CSS retains WOFF/WOFF2 font fallbacks; TTF fallbacks were removed
because VisLlama's existing public asset allowlist serves WOFF/WOFF2. Font files
are supplied locally under public/assets/css/chat/fonts/. No private files become
static assets. Custom glue/rendering logic is VisLlama source outside vendor/.

The application uses DOMPurify before mounting Markdown, KaTeX with trust:false,
and explicit highlighting only for known languages. Dependency updates should
re-run chat_rendering.js and the full supplied release checks and update these
versions, licenses and SHA-256 records together.

## SHA-256 of bundled files

See third-party/chat-assets.sha256 for every vendored script, stylesheet and font.
