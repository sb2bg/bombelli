/* Executes the emitted C gradient evaluator and prints its results for
   comparison against Bombelli's own evaluator. */

#include <stdio.h>

#include "generated_gradient.c"

int main(void) {
    generated_gradient_inputs inputs;
    double values[2];

    inputs.x = 0.6;
    inputs.y = -1.3;
    generated_gradient(&inputs, values);

    printf("gradient_x %.17g\n", values[0]);
    printf("gradient_y %.17g\n", values[1]);
    return 0;
}
