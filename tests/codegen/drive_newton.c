/* Executes the emitted C Newton solver and prints its results for comparison
   against Bombelli's own evaluator. */

#include <stdio.h>

#include "generated_newton.c"

int main(void) {
    generated_newton_inputs inputs;
    generated_newton_result result;

    inputs.initial.x = 0.7;
    inputs.initial.y = 0.7;
    inputs.r = 1.0;
    generated_newton(&inputs, &result);

    printf("newton_status %d\n", (int)result.status);
    printf("newton_iterations %lu\n", (unsigned long)result.iterations);
    printf("newton_x %.17g\n", result.values[0]);
    printf("newton_y %.17g\n", result.values[1]);
    printf("newton_residual_norm %.17g\n", result.residual_norm);
    return 0;
}
