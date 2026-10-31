# Filter classifier inventory

The October 28 inspection found these bounded gaps. Existing examples remain useful; they do not establish every rejected set or filter combination.

| Boundary | Existing coverage | Next control |
| --- | --- | --- |
| Search candidate filtering | Standalone path-set regression across vector, hybrid, lexical, and browse modes; Roc signature paths | Retain complete returned-set assertions when adding constraints |
| Search filter construction | Forty-eight language/type combinations, weight-validation controls, and six real-CLI checks | Retain the distinction between absent restrictions and empty required intersections |
| Discovery defaults | Selected ignored directories, Git/symlink sets, Python environments | Supported source files beneath every tested ignored directory plus similarly named allowed neighbors |
| Compiled glob sets | Literal/wildcard examples, lazy combination, add-after-finalize | The same positive/negative path set before and after adding patterns, including alternate basenames |

The standalone-path regression failed first on the vector case: two allowed paths were expected, but all four candidates returned. The complete Nix check reported exactly one failed unit case alongside 755 passes and one optional skip; the remaining available suites passed. The post-gather gate checked language, extension, and symbol-kind restrictions before calling the shared matcher, but omitted paths. The existing browse test also supplied a symbol-kind filter and could not expose that omission.

The minimal repair adds paths to that gate. The complete Nix check and fresh confined host runner pass 756 unit cases with the same optional OS-log skip and two live-provider suite exclusions. The regression covers four search invocations (vector, hybrid, lexical, and browse) against independently declared admitted/rejected sets for one path pattern, a pattern union, match-none, and match-all. All 16 combinations pass. It rejects duplicates and unexpected candidates and checks the total count. Current wildcard semantics, ranking, candidate limits, and embedding behavior are unchanged; the test does not establish recall beyond the gathered candidate window.

## Empty language/type intersections

The October 30 regression uses five candidates spanning code, document, text, and log types. Twelve declared filter sets run through vector, hybrid, lexical, and browse search. The matrix includes matching intersections, contradictory restrictions, language-only filters, defaults, and an all-types control. The first disjoint case expected no candidates but returned all five. The complete Nix run reported exactly one failed unit case, 757 passes, and one optional skip. A separate real-CLI control also failed: `--lang zig --type doc` returned three checksum matches instead of none.

The filter builder already computed the empty intersection correctly. The domain search treats an empty language list as an absent restriction, so the service lost that constraint when forwarding the resolved list. An initial service shortcut returned the correct empty set but bypassed invalid hybrid-weight errors. An added control failed with `ExpectedInvalidWeights`, while the other available suites passed. The revised repair carries an explicit empty-intersection flag into the domain search, preserving normal weight validation before returning no candidates. Browse, zero-result limits, and Roc signature queries retain their existing weight-validation exemptions.

The complete Nix check and fresh confined host runner pass 758 unit cases with one optional OS-log skip and the unchanged two live-provider suite exclusions. All 48 language/type combinations, three invalid-weight checks, nine exemption controls, and six real-CLI checks pass. The CLI controls cover contradictory query/browse requests and matching code/document requests. Wildcard behavior, ranking, candidate limits, and request deadlines are unchanged.
