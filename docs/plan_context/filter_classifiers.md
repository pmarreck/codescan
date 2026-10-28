# Filter classifier inventory

The October 28 inspection found these bounded gaps. Existing examples remain useful; they do not establish every rejected set or filter combination.

| Boundary | Existing coverage | Next control |
| --- | --- | --- |
| Search candidate filtering | Language/extension examples, browse-path example, Roc signature paths | Standalone path restriction over a mixed candidate set in vector, hybrid, lexical, and browse modes |
| Search filter construction | Selected default code languages and documentation widening | Exact admitted/rejected fixture languages, explicit language/type intersections, and an empty intersection |
| Discovery defaults | Selected ignored directories, Git/symlink sets, Python environments | Supported source files beneath every tested ignored directory plus similarly named allowed neighbors |
| Compiled glob sets | Literal/wildcard examples, lazy combination, add-after-finalize | The same positive/negative path set before and after adding patterns, including alternate basenames |

Start with standalone search paths. The post-gather gate currently checks language, extension, and symbol-kind restrictions before calling the shared matcher; its condition omits paths. The existing browse test also supplies a symbol-kind filter and therefore cannot establish standalone vector/hybrid behavior. Treat this as a candidate bug until a persistent end-to-end regression fails. Assert the complete returned set, including no-match paths, rather than the presence of one expected result. Preserve current wildcard semantics; changing them is a separate decision.
