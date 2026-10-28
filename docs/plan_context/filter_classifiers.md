# Filter classifier inventory

The October 28 inspection found these bounded gaps. Existing examples remain useful; they do not establish every rejected set or filter combination.

| Boundary | Existing coverage | Next control |
| --- | --- | --- |
| Search candidate filtering | Language/extension examples, browse-path example, Roc signature paths | Standalone path restriction over a mixed candidate set in vector, hybrid, lexical, and browse modes |
| Search filter construction | Selected default code languages and documentation widening | Exact admitted/rejected fixture languages, explicit language/type intersections, and an empty intersection |
| Discovery defaults | Selected ignored directories, Git/symlink sets, Python environments | Supported source files beneath every tested ignored directory plus similarly named allowed neighbors |
| Compiled glob sets | Literal/wildcard examples, lazy combination, add-after-finalize | The same positive/negative path set before and after adding patterns, including alternate basenames |

The standalone-path regression failed first on the vector case: two allowed paths were expected, but all four candidates returned. The complete Nix check reported exactly one failed unit case alongside 755 passes and one optional skip; the remaining available suites passed. The post-gather gate checked language, extension, and symbol-kind restrictions before calling the shared matcher, but omitted paths. The existing browse test also supplied a symbol-kind filter and could not expose that omission.

The minimal repair adds paths to that gate. The complete Nix check and fresh confined host runner pass 756 unit cases with the same optional OS-log skip and two live-provider suite exclusions. The regression covers four search invocations (vector, hybrid, lexical, and browse) against independently declared admitted/rejected sets for one path pattern, a pattern union, match-none, and match-all. All 16 combinations pass. It rejects duplicates and unexpected candidates and checks the total count. Current wildcard semantics, ranking, candidate limits, and embedding behavior are unchanged; the test does not establish recall beyond the gathered candidate window.
