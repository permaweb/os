# Linux No-TME Runtime

`make no-tme` builds the common Linux appliance with the measured
`LAPEE_NO_TME=1` command-line flag. This is for hardware that cannot satisfy
TME/SME policy; verifiers and zones can accept or reject that evidence.
