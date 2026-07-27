/* Executes the emitted C quadrature rule and prints its result for comparison
   against Bombelli's own evaluator. */

#include <stdio.h>

#include "generated_quadrature.c"

int main(void) {
    generated_quadrature_inputs inputs;
    double value;

    inputs.from = 0.0;
    inputs.to = 1.0;
    inputs.k = 2.0;
    generated_quadrature(&inputs, &value);

    printf("quadrature %.17g\n", value);
    return 0;
}
