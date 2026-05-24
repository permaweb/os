# Linux No-TME Runtime

`make no-tme` builds the common Linux appliance with the measured
`LAPEE_NO_TME=1` command-line flag. This is for hardware that cannot satisfy
TME/SME policy, and for zones that intentionally admit LPDDR or other
physically constrained machines.

No-TME is not a memory-encryption guarantee. Its useful security comes from
the single-purpose appliance model plus measured hardware facts such as
controller-observed LPDDR, Secure Boot state, firmware evidence, and explicit
zone policy.
