#include <stdio.h>
#include "generated_jvp.c"

int main(void) {
    generated_jvp_inputs inputs = {
        .x = 0.6, .y = -1.3, .bombelli_seed_0 = 0.7, .bombelli_seed_1 = -0.2
    };
    double values[2];
    generated_jvp(&inputs, values);
    printf("jvp_0 %.17g\njvp_1 %.17g\n", values[0], values[1]);
    return 0;
}
