/* Executes the emitted C expression evaluator and prints its results for
   comparison against Bombelli's own evaluator. */

#include <stdio.h>

#include "generated_expression.c"

int main(void) {
    generated_expression_inputs inputs;
    double value;

    inputs.x = 1.25;
    inputs.y = -0.75;
    generated_expression(&inputs, &value);

    printf("expression %.17g\n", value);
    return 0;
}
