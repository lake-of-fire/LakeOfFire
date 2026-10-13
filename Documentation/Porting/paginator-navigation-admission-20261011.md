# Paginator admission result repair, 2026-10-11

Parent source review at #138 366e10da57bb7752a4feb0faeb7e2ab8ccf14b1d corroborated a second silent-rejection path: Paginator.goTo returned undefined while a page turn held its lock or a target index was out of range. Required restoration accepts legacy successful void returns, so rejection needed an explicit result.

## Changes
- Locked and invalid target navigation returns null.
- The page-turn lock is checked again after awaiting an asynchronous target.
- Section index admission requires an integer; coercible strings, fractions and missing targets do not reach section loading.
- Successful existing renderer work and current exceptions keep their existing contract. No pagination, prefetch, layout or page-turn timing algorithm changed.

## Coverage and evidence
Four new cases in paginator-navigation-admission.test.mjs call the actual Paginator with a minimal browser host: invalid required restore, valid target exception preservation, active page-turn lock and a lock acquired while resolving a target. A deliberately failing section source releases the page-turn path through its existing finally cleanup; no real iframe or native host is launched.

All cases UNRUN. Static inspection only, no builds/tests/CI dispatch. Tests are not evidence of runtime success until executed. The earlier fixed-layout gap is repaired in the preceding commit.

Remaining deeper renderer cancellation during in-flight content/layout work, native owned-serving/cache integration and end-to-end restore validation are not claimed complete. #50 remains open.
