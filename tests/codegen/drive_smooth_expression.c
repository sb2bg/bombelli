/* Executes emitted C99 smooth elementary functions and prints the result for
   comparison against Bombelli's evaluator. */

#include <stdio.h>

#include "generated_smooth_expression.c"

int main(void) {
    generated_smooth_expression_inputs inputs;
    double value;

    inputs.u = 0.35;
    inputs.v = -0.2;
    inputs.a = 3.25;
    inputs.b = 12.5;
    generated_smooth_expression(&inputs, &value);

    printf("smooth_expression %.17g\n", value);
    return 0;
}
