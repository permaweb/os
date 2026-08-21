# Android device package

This directory is the Android-specific overlay for the PermawebOS device
package. It owns the `andock@1.0` Android adapter and the local
`andee-inference@1.0` provider, and consumes the neutral execution contract from
`devices/common/src/sandbox/`. Applications select these capabilities through
normal named-device resolution; neither device has an application source or
build dependency.

Build and test it from this directory alone:

```sh
make test
```

The Andock trusted-device archive contains `dev_andock`, the Android transport
adapter, and the shared neutral PermawebOS execution contract. The package
boundary test rejects application and foreign-backend modules.

The inference-provider archive contains only the OpenAI-compatible AO adapter and its
private framed-socket transport. LiteRT-LM, model validation, and accelerator
selection remain in the Android service. Its package boundary test rejects
application, remote-provider, and foreign-execution modules while retaining
the generic OpenAI-compatible wire shape.

The public contract includes the seven ordinary Unix tools and
`bash-session`, which polls or terminates a background `Bash` execution using
the same Bash authorization capability.
