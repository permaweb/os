# Android device package

This directory is the Android-specific overlay for the PermawebOS device
package. It owns the `andock@1.0` Android adapter and consumes the neutral
execution contract from `devices/common/src/sandbox/`. Applications select Andock
through their normal execution-engine option; the device has no application
source or build dependency.

Build and test it from this directory alone:

```sh
make test
```

The Andock trusted-device archive contains `dev_andock`, the Android transport
adapter, and the shared neutral PermawebOS execution contract. The package
boundary test rejects application and foreign-backend modules.

The public contract includes the seven ordinary Unix tools and
`bash-session`, which polls or terminates a background `Bash` execution using
the same Bash authorization capability.
