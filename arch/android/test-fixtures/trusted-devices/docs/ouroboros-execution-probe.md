# `ouroboros-execution-probe@1.0`

Test-only adapter which calls the real Ouroboros execution client captured from
a separately supplied, provenance-checked application checkout. The package is
loaded after Android boot and is never included in AndEE's build graph.
