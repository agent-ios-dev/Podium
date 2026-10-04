#include <stdio.h>

static void __attribute__((constructor)) podium_substrate_probe(void) {
    FILE *marker = fopen(
        "/private/var/mobile/Library/Preferences/PodiumSubstrateInjectionProbe",
        "w"
    );
    if (marker != NULL) {
        fputs("SpringBoard tweak constructor ran\n", marker);
        fclose(marker);
    }
}
