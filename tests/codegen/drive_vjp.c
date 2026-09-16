#include <stdio.h>
#include "generated_vjp.c"

int main(void) {
    generated_vjp_inputs inputs = {
        .x = 0.6, .y = -1.3, .bombelli_seed_0 = 0.7, .bombelli_seed_1 = -0.2
    };
    double values[2];
    generated_vjp(&inputs, values);
    printf("vjp_0 %.17g\nvjp_1 %.17g\n", values[0], values[1]);
    return 0;
}
