# EPUB late font-state notification port

Reviewed 2026-10-13 against hotfix Lake 036d4193078016db0becdf91b86dd34fb1d579e0, main 8985bf92b9504d53e00025e4054b3aa97f876e45, and draft #138 0682edc42658b76ad6298e19cfc66832c21f2c3d.

## Missing behavior and adaptation
The hotfix ReaderDocStateUserScript observes only the root data-mnb-font-pending attribute for EPUB. Font completion can clear that flag after the renderer's one readiness event. The inspected main, #50 (11b71f294a530cf38352065bceb05ce10aa88aa7), #138 and #191 (4e3a8e41eccf1012e6e2654afe6a74d08ba8cfc7) scripts were byte-identical and returned before attaching the EPUB observer.

This port retains that narrow notification without polling or observing the EPUB subtree. It adapts the probe to main's existing foliate-view host and manabiReaderRenderReady marker. The article's mnbReaderRenderReady contract and visibility/font gating remain. The viewer producer and its display-settled consumers are unchanged.

The earlier #138 font-forwarding work (comment 6108558110) handles child-document font geometry and is not equivalent to this root document-state notification. This finding supersedes only an assumption that such forwarding already covers the notification; it does not invalidate its geometry implementation.

## Authority and limits
Native ReaderMessageHandlersViewModifier and ReaderModeViewModel URL/generation admission are unchanged. A JavaScript ready report is not proof of native acceptance. Core's EPUB loading overlay separately recognizes loaded/resolved ebook shells. No spinner defect, placement failure cause, or release blocker is demonstrated by this source finding.

The observer remains one-shot, disconnecting when JavaScript reports ready, matching the donor. This does not add rearming for subsequent font changes, a native acceptance acknowledgment, or recovery of renderer events before script installation.

## Validation
Three JavaScript regression declarations evaluate the actual injected Swift string: late font clearance after a renderer event, required host/marker/visibility, and preserved article behavior including rejection of the EPUB-only marker. Native URL/generation rejection requires separate integration qualification.

Static source review only. Tests, builds, compilation, WebKit integration and CI are UNRUN. No root pins, native execution, merges or deployments. Existing task owner was read as completed before publication; branch publication uses an expected-head lease.
