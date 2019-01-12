#include <iostream>
#include <algorithm>
#include <sys/time.h>
#include "src/host_functions.h"
#include "src/nfa_kernels.h"
#include "src/state_vector.h"
#include "src/mem_alloc.h"

using namespace std;

// Host function to run iNFAnt algorithm on GPU
// This function can process multiple strings on a NFA simultaneously
// tg                   :  NFA transition graph
// h_input_array        :  array of input string in host memory
// input_bytes_array    :  array of string length
// array_size           :  array size (# of strings to match)
// threads_per_block    :  # of threads per block for kernel function
// show_match_result    :  print regex matching result if this variable is true
vector<int>* run_nfa(class TransitionGraph *tg,
             unsigned char **h_input_array,
             int *input_bytes_array,
             int array_size,
             int threads_per_block,
             bool show_match_result,
             bool profiler_mode)
{
        if (tg->kernel == iNFA) return run_iNFA(tg, h_input_array, input_bytes_array, array_size, threads_per_block, show_match_result, profiler_mode);
        if (tg->kernel == TKO_NFA) return run_TKO(tg, h_input_array, input_bytes_array, array_size, threads_per_block, show_match_result, profiler_mode);
        if (tg->kernel == AS_NFA) return run_AS(tg, h_input_array, input_bytes_array, array_size, threads_per_block, show_match_result, profiler_mode);
}
