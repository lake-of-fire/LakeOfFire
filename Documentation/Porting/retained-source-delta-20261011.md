# Retained Lake source delta checkpoint — 2026-10-11

Exact compared heads: retained #50 `11b71f294a530cf38352065bceb05ce10aa88aa7`; composed #138 `4855d60d4c3ab2db4a6335bf079f42b35597e5b2`. Forty source paths differ. A differing blob is not itself a missing port; the comparison includes newer main architecture and repaired behavior. This is a source inventory, not native qualification.

## Freshly reviewed decisions

- `ReaderFileImportStorage.swift`: retain main's additional admission checks before/after async storage work. Copying the retained file would remove these checks.
- `URL+GoogleQuery.swift`: retain main's one-pass decoding of encoded parameter names as well as values. The older version recognizes only literal q names.
- `LibraryConfiguration+Consolidation.swift`: retain current final-transaction candidate admission/order and reachable disabled scripts. The older implementation filters archived/disabled scripts out of relationships. Main explicitly preserves them for re-enabling; do not interpret this difference as a missing archive filter.
- `BookLibraryView.swift` differs only by main's in-file Publication declaration. The older separate Publication.swift is a placement difference, not an absent model.
- `ebook-native-lookup-publication.js` and the viewer lack the retained payload/producer-generation fields. Core #183 `e71646312b548e694dd878ffc79410f063347f4f`'s actual manabi_reader.js also lacks that generation consumer. Treat this as a paired lookup pipeline gap, not a reason to copy the older viewer wholesale.
- `native-mark-read-request.js`: retained code adds captured-message redelivery using the same request ID. Do not enable automatic replay until the current native commit/receipt deduplication contract is reviewed with it. The current one-delivery implementation is intentionally left unchanged in this pass.
- `ReaderEbookTextProcessor.swift` / `ReaderExternalSegmentSidecar.swift`: retained completion proofs, cache envelope v6 and final admission are a paired producer/API migration. Main's existing bounded persisted reads are already present and must not be duplicated. Disk retention/descriptor leases remain a separate open source gap.

## Additional retention review concerns

Read the complete retained sidecar store and its 14-case regression file. Retained lease expiration filters leasedTokensUntil but leaves currentLeaseURLs entries for expired tokens; review bounded metadata lifetime before carrying that implementation. Its cross-store lease test is sequential and does not establish atomicity between another store acquiring a lease and pruning a previously enumerated object. A concurrent renewal-versus-prune regression is still needed before claiming cross-store protection. These are review concerns, not executed reproductions. Do not replace main's currently non-pruning store with the older cleanup implementation merely to reduce the diff.

The retained regression file also mixes sidecar store, scheme-handler, processing-actor and legacy sidecar-schema cases. Adapt only against actual current APIs; do not treat old test source as automatically buildable. Nothing was executed.

## Exact differing source blobs

The following paths remain differing after the native-loader and diagnostic-frame fixes. Some are already intentionally preserved above; the rest still require behavior-level classification or their existing audit evidence. No blanket supersession is asserted.

| Path | Retained #50 blob | Composed #138 blob |
| --- | --- | --- |
| `Sources/LakeOfFireContent/Feeds/Feed Models.swift` | `4da8b488ba557d35586af32fda199a7d6c54a64c` | `1f0eafa176e1568476a7d16abe50f87d45bc981e` |
| `Sources/LakeOfFireContent/Files/ReaderFileImportStorage.swift` | `468328a020129e09bab53b9dc5289089c11d57db` | `86dd9a81aece30675718c8915decc858e2470057` |
| `Sources/LakeOfFireContent/Files/ReaderFileManager.swift` | `7900229e303a972508af552886463fa21f6d2c0e` | `282bfb835e8632d75d53c4ba96089e1ab13bf204` |
| `Sources/LakeOfFireContent/Library/LibraryConfiguration+Consolidation.swift` | `e577aa625911811352d4d463f1bcf65dc9d36ee5` | `f4c867dcf7be5072e00e75c1baa0ee896bb3c8b9` |
| `Sources/LakeOfFireContent/Library/LibraryDataManager.swift` | `12ba3d1150a6701fb19ac666abb294e9ae07f567` | `e500381839339f68e2dcc63bc314d4e011c51e69` |
| `Sources/LakeOfFireContent/Reader/ReaderContent.swift` | `ba060b80f41112e3d481b276c5a8e8826fac46f6` | `c2d99b564738986a8175815ef13ea8f381cb14de` |
| `Sources/LakeOfFireContent/Reader/ReaderContentLoader.swift` | `42e9179cc009cc572d3e687484998a91c48c59c7` | `c6dec0051da7e7e1990ae947181bb4b1b4ebc879` |
| `Sources/LakeOfFireContent/Reader/ReaderContentProtocol.swift` | `cc417d2f180b248fbe62b747b654e5eaac384b8c` | `fe62ec9e7280aa86199be262078b604fed55f7ff` |
| `Sources/LakeOfFireContent/Web/HistoryRecord.swift` | `76e9b1552002460b0df2603df76893d0ed3f76d0` | `feefeac104ae1868eb86d8348d28eb0475f83122` |
| `Sources/LakeOfFireContentUI/Reader Content/ReaderContentCell.swift` | `bea1740bca51136c22824ad8b234e1663962ad0b` | `47a1accc91ed3dd47394ec6c0058d47fff2a82c5` |
| `Sources/LakeOfFireContentUI/Reader Content/ReaderContentList.swift` | `6bf60915cc695ab1629240f4c6eb775bb699d214` | `aad43988cc4678fd6e8725f793caf0e5fe4af83e` |
| `Sources/LakeOfFireCore/URL+GoogleQuery.swift` | `29fa7e54f0c3fdf0559321114eaba91d97dbf099` | `29f780e69da6cabdc6802d0a72df37c66bc97c4c` |
| `Sources/LakeOfFireLibrary/Library/LibraryCategoriesView.swift` | `3a197732fc778f4e12704eda60b96254533fddb9` | `52c98befc71a42f1443c4fb7694d88ac737104ce` |
| `Sources/LakeOfFireLibrary/Library/LibraryCategoriesViewModel.swift` | `12c608fab487e655e22b604b83e4bf7bb7770da5` | `ccc52cbb736ec50e123b2e4a206f727b7369a663` |
| `Sources/LakeOfFireLibrary/Library/LibraryCategoryView.swift` | `6579a855bab22f9a371a3dc375d6a4764b4e0e5e` | `c726771c7ca42bb62b0890cf4e9afec45b0fe9d8` |
| `Sources/LakeOfFireLibrary/Library/LibraryDataManager+Categories.swift` | `f04e9c233c8d8245f0182315f7f91c2207ba6a6f` | `f92b8447edda51283f6ebae29abe93edfa603f61` |
| `Sources/LakeOfFireLibrary/Library/LibraryFeedView.swift` | `c5f5ae04f22123ca527a9c21d7c2600f23ff5d41` | `6bfbae0ba98d15df32e76626ad35ae63db3589a7` |
| `Sources/LakeOfFireLibrary/Library/LibraryManagerView.swift` | `db41e39900bf6ce578e07778913ad30c53b39b15` | `32480af13ccdf6f5ba031674e05c0d1885dfced8` |
| `Sources/LakeOfFireLibrary/Library/LibraryManagerViewModel.swift` | `f768f829b0ad9def21af7ff98d3233a48fc22652` | `5eba366d4eba0a93a96e67e1ea5204690a289462` |
| `Sources/LakeOfFireLibrary/Library/LibraryScriptFormSections.swift` | `8bb5c7a571d4672d470eae5244c6ab06c5ead900` | `0712e15055cbdbabeac565241481d3ab6ae1be3b` |
| `Sources/LakeOfFireLibrary/Library/LibraryScriptsListView.swift` | `32ad54320cadd1eb9a45eba4363ac15b87d89c35` | `5ba088e7c55d5766a84cd768f8d5192084956859` |
| `Sources/LakeOfFireLibrary/Library/UserScriptAllowedDomainCell.swift` | `ada21426f8dd066ac570bf51aab3dc704544334f` | `6e0c78732b553b1d107d80d6e3003f51b0336693` |
| `Sources/LakeOfFireReader/Reader/Books/BookLibraryView.swift` | `28b61484c13fa558cbf8556992b4f94025216815` | `7c687798a7d60eac20c6bd0412c52aff78c2cad1` |
| `Sources/LakeOfFireReader/Reader/Books/EPubParser.swift` | `3cb3d341d6a2ef803580054dbc41d6c549691e97` | `ab5c578e3a7718dc573402aa924bb81b5c5029e5` |
| `Sources/LakeOfFireReader/Reader/Books/EbookEntryPathTransport.swift` | `d0ac7b773836770d9156e7c4f927b830a1628ccd` | `03b4c7b5731e93963fe6c1ef8168f4ff5963f65d` |
| `Sources/LakeOfFireReader/Reader/Books/EbookURLSchemeHandler.swift` | `c15523ce3a82c3bc78703e88695462bc11aaa5d1` | `665ade29b6c31ca9f05af57a2e0a196ea4666b20` |
| `Sources/LakeOfFireReader/Reader/Books/Publication.swift` | `44c5b27ad7a518573f144e1e5e8847acc0027fb4` | absent at this path |
| `Sources/LakeOfFireReader/Reader/Reader.swift` | `55840d963edf14e315e04354ac6aaed2e56e8146` | `2ba8d3486748571e9d9540f8de6c4ff9b322b8ab` |
| `Sources/LakeOfFireReader/Reader/ReaderEbookTextProcessor.swift` | `2eec95f5330a293c55a2b37acb649d2ae42f240d` | `90f3e6d8b4ff0a755eefab8a94f5e2d78b7d4578` |
| `Sources/LakeOfFireReader/Reader/ReaderExternalSegmentSidecar.swift` | `9a736c5dbdd96de58f72fa3304c172722090a525` | `69b330b17d2b3d1590022e8fbfcf9c716e8d2d6d` |
| `Sources/LakeOfFireReader/Reader/ReaderJavascriptMessages.swift` | `e1028389a10c71be3eaf1510ed237d5d97f635fc` | `492ee46fd7beced4416fee141bbf15e625a45b8d` |
| `Sources/LakeOfFireReader/Reader/ReaderMessageHandlersViewModifier.swift` | `90dc6a6f0b1fad245095957ded6663721071cdb6` | `eb51eb2888773265945d9e070c3c7fbd797b00a8` |
| `Sources/LakeOfFireReader/Reader/ReaderModeViewModel.swift` | `d44f325cba5a20e2f9ecc78ce5d7df7a1ab1e00a` | `3f551f88f6530f8573e9ad3c2e007fb13c03f94c` |
| `Sources/LakeOfFireReader/Reader/ReaderViewModel.swift` | `7838d75ad2b8926e3097bacc707a22b4baf41909` | `3fb36e6e5bead7734cee6906dc7d31f86a8ed527` |
| `Sources/LakeOfFireReader/Reader/ReaderWebView.swift` | `267df3ae4f8057a8cb6d8b1ed50a7599ffbea6bf` | `89151e03a2f8b318773fff7c23164cbd2816cae7` |
| `Sources/LakeOfFireReader/Reading Progress/ArticleReadingProgress.swift` | `042acdf70efe765d5d2746b0343f4e284d53db78` | `f236ad63bdb0aed7bbcf4fb11d02b9d082996a91` |
| `Sources/LakeOfFireReader/Resources/foliate-js/ebook-native-lookup-publication.js` | `0d9aacb0bc79f2d30a27f6984c070af91c16902d` | `53fc71ba266e315750f4ca9d058f7bcb4b761ccd` |
| `Sources/LakeOfFireReader/Resources/foliate-js/ebook-package-media.js` | `98e7b161350c17cb6192ad19cdc90fcbfed79843` | `00989381ca0b7a04a63a40eeb8c48153584b7e8f` |
| `Sources/LakeOfFireReader/Resources/foliate-js/ebook-viewer.js` | `8426ac733dae35c77c6e768928c09d3a8805a05e` | `c0cf723309c68a7444ef8a7446ec28bb693a968b` |
| `Sources/LakeOfFireReader/Resources/foliate-js/native-mark-read-request.js` | `23fdfe3bfa72a2d8401486b21c36b30c3a9138f2` | `cfd22a166a2f1b054444a8559889ecd52c208d35` |

## Next bounded work

Finish paired lookup generation/receipt reconciliation and processing completion/cache admission without enabling passive Common compatibility models as active reading authority. Review current opening-producer lifetime before publishing the prepared optional environment wiring. Swift UNCOMPILED; JavaScript and native tests UNRUN. No native launches, builds, project generation, CI dispatches, pins, merges, deployment or production changes.
