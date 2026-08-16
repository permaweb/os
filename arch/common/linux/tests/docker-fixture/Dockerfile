FROM alpine@sha256:7c8cb692ae09657cbc4a3f3cbd0e8d5a2690ba38386aaaf252dbb060bf5eb2e6 AS build

RUN apk add --no-cache build-base=0.5-r3
COPY resource-probe.c /src/resource-probe.c
RUN cc -O2 -static -Wall -Wextra -Werror \
        -o /out-resource-probe /src/resource-probe.c

FROM alpine@sha256:7c8cb692ae09657cbc4a3f3cbd0e8d5a2690ba38386aaaf252dbb060bf5eb2e6

RUN apk add --no-cache \
        bash=5.2.37-r0 \
        coreutils=9.7-r1 \
        findutils=4.10.0-r0 \
        grep=3.12-r0 \
        python3=3.12.14-r0 \
        ripgrep=14.1.1-r0
COPY --from=build /out-resource-probe /usr/local/bin/resource-probe

WORKDIR /root
CMD ["sleep", "infinity"]
