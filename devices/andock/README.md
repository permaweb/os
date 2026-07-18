# `andock@1.0` device package

This directory owns the Android execution backend adapter. The application
selects it through the ordinary `ouroboros-execution-device` node option; no
Andock implementation is present in the Ouroboros application package.

The public seven-tool contract remains single-sourced in Ouroboros. Supply a
clean generic Ouroboros checkout when packaging or testing:

```sh
OUROBOROS_SRC=/path/to/ouroboros make test
```

The package script rejects an Ouroboros checkout that contains an Andock
backend implementation. The resulting archive contains this directory's
`dev_andock` and `lib_andock` modules together with the shared execution
contract and utilities needed to run independently after loading.
