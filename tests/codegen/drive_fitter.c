/* Executes the emitted C runtime-observation fitter and prints its results
   for comparison against Bombelli's own evaluator. */

#include <stdio.h>

#include "generated_fitter.c"

int main(void) {
    generated_fitter_observation observations[4] = {
        {0.0, 1.0},
        {1.0, 3.0},
        {2.0, 5.0},
        {3.0, 7.0},
    };
    generated_fitter_inputs inputs;
    generated_fitter_result result;

    inputs.initial.offset = 0.5;
    inputs.initial.slope = 0.5;
    inputs.observations = observations;
    inputs.observation_count = 4;
    generated_fitter(&inputs, &result);

    printf("fitter_status %d\n", (int)result.status);
    printf("fitter_iterations %lu\n", (unsigned long)result.iterations);
    printf("fitter_rank %lu\n", (unsigned long)result.rank);
    printf(
        "fitter_function_evaluations %lu\n",
        (unsigned long)result.function_evaluations
    );
    printf("fitter_offset %.17g\n", result.values[0]);
    printf("fitter_slope %.17g\n", result.values[1]);
    printf("fitter_cost %.17g\n", result.cost);
    printf("fitter_gradient_norm %.17g\n", result.gradient_norm);

    inputs.observation_count = 0;
    generated_fitter(&inputs, &result);
    printf("fitter_empty_status %d\n", (int)result.status);

    inputs.initial.slope = -0.5;
    inputs.observation_count = 4;
    generated_fitter(&inputs, &result);
    printf("fitter_infeasible_status %d\n", (int)result.status);

    inputs.initial.slope = 0.5;
    observations[2].y = NAN;
    generated_fitter(&inputs, &result);
    printf("fitter_nonfinite_observation_status %d\n", (int)result.status);
    return 0;
}
